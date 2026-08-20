use strict;
use warnings;
use Test::More;
use Path::Tiny qw( path tempdir );
use PPI;

use App::karr::Foundation;
use App::karr::Foundation::Limits;

# Ticket #214: karr-foundation's own messages are ASCII.
#
# F<bin/karr-foundation> calls App::karr::Encoding::enable_std_utf8() before it
# builds anything, so through the script an em dash in a warning comes out
# right. Loaded as a module it does not: t/31-foundation-drain.t and
# t/33-foundation-run.t say `App::karr::Foundation->new` and nothing else, and
# every one of those runs printed
#
#     Wide character in warn at lib/App/karr/Foundation.pm line 188.
#
# on the way past. Noise in a test run that hides real warnings, and for anyone
# using the distribution as a library the same warning with no test harness
# around it.
#
# The fix is the message, not the handle. A library must not push an
# :encoding(UTF-8) layer onto the caller's STDERR: those layers stack, so a
# "just make sure" binmode on a handle that already carries one is a double
# encode, and CLAUDE.md gives the two crossings for the standard handles to
# App::karr::Encoding, called from the two scripts in F<bin/>. So the character
# goes instead -- an em dash in "config not found -- nothing to do" carries
# nothing a "--" does not.
#
# Two halves below: the warnings really do come out clean on an unconfigured
# handle, and no message in the foundation subsystem carries a non-ASCII
# character in the first place. The first is the bug; the second is the class,
# so the next message with a special character in it fails here rather than in
# somebody's terminal.

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Run $code with STDERR redirected to a file that carries NO encoding layer --
# exactly the state an in-process caller leaves it in -- and return the raw
# bytes that landed there. Perl's own "Wide character in warn" goes to the same
# handle, so it is captured along with the message it complains about.
sub stderr_bytes {
  my ($code) = @_;
  my $file = Path::Tiny->tempfile;
  open my $saved, '>&', \*STDERR or die "dup STDERR: $!";
  open STDERR, '>', "$file"      or die "reopen STDERR: $!";
  my $ok  = eval { $code->(); 1 };
  my $err = $@;
  open STDERR, '>&', $saved or die "restore STDERR: $!";
  close $saved;
  die $err unless $ok;
  return $file->slurp_raw;
}

# Report the offending bytes by name rather than printing mojibake back.
sub spell {
  my ($text) = @_;
  ( my $shown = $text ) =~ s/([^\x20-\x7e\n])/sprintf '<%02x>', ord $1/ge;
  return $shown;
}

sub clean_ok {
  my ( $bytes, $expect, $name ) = @_;
  subtest $name => sub {
    like $bytes, $expect, 'the message came out at all';
    unlike $bytes, qr/Wide character/,
      'perl did not complain about a wide character' or diag spell($bytes);
    unlike $bytes, qr/[^\x00-\x7f]/,
      'and nothing non-ASCII reached the handle' or diag spell($bytes);
  };
}

# Temporary directories outlive the sub that made them: Path::Tiny removes one
# the moment its object goes out of scope, and every config here is read lazily,
# long after the helper has returned.
my @KEEP;

sub keep_tempdir {
  push @KEEP, tempdir( CLEANUP => 1 );
  return $KEEP[-1];
}

# A foundation pointed at a config of our own making, so nothing on the machine
# running the tests is read.
sub foundation_with {
  my ($yaml) = @_;
  my $cfg = keep_tempdir()->child('config.yml');
  $cfg->spew_utf8($yaml);
  return App::karr::Foundation->new( config => "$cfg" );
}

# ---------------------------------------------------------------------------
# The warnings, on a handle nobody configured
# ---------------------------------------------------------------------------

subtest 'a missing config warns without a wide character' => sub {
  # The default path resolves under HOME; move it somewhere empty so the
  # warning is about a file that really is not there.
  local $ENV{HOME} = keep_tempdir()->stringify;
  my $f = App::karr::Foundation->new;
  my $bytes = stderr_bytes( sub { $f->_config_data } );
  clean_ok( $bytes, qr/config not found/, 'config not found' );
};

subtest 'an empty config warns without a wide character' => sub {
  my $f = foundation_with("dirs: []\n");
  my $bytes = stderr_bytes( sub { $f->run } );
  clean_ok( $bytes, qr/no repos found/, 'no repos found' );
};

subtest 'a bad chain limit warns without a wide character' => sub {
  my $f = foundation_with("dirs: []\n");
  my $limits = App::karr::Foundation::Limits->new(
    foundation   => $f,
    chain_limits => { concurrent => 'two' },
  );
  my $bytes = stderr_bytes( sub { $limits->concurrent } );
  clean_ok( $bytes, qr/ignored/, 'a chain number that is not one' );
};

subtest 'a malformed per_agent warns without a wide character' => sub {
  my $f = foundation_with("dirs: []\n");
  my $limits = App::karr::Foundation::Limits->new(
    foundation   => $f,
    chain_limits => { per_agent => 'minimax' },
  );
  my $bytes = stderr_bytes( sub { $limits->per_agent } );
  clean_ok( $bytes, qr/per_agent/, 'a per_agent that is not a mapping' );
};

# ---------------------------------------------------------------------------
# The class: no non-ASCII in any foundation message
# ---------------------------------------------------------------------------
#
# t/124-source-ascii-only.t polices literal non-ASCII *bytes* in source under
# lib/ and bin/, and its cure is to spell the character as "\x{2014}". This
# goes one step further for the foundation subsystem: the character itself is
# unwanted there, however it is written. Only string literals are scanned --
# not regexes, where a \x{...} is a perfectly good way to match a byte range,
# and not comments or POD, which are prose and keep their dashes.

my %LITERAL = map {; ( "PPI::Token::$_" => 1 ) } (
  'Quote::Single', 'Quote::Double', 'Quote::Literal', 'Quote::Interpolate',
  'QuoteLike::Words', 'HereDoc',
);

# Every non-ASCII character in a string literal of $file, raw or escaped.
sub scan_file {
  my ($file) = @_;
  my $doc = PPI::Document->new("$file")
    or die "PPI could not parse $file: " . PPI::Document->errstr . "\n";
  my @found;
  $doc->find( sub {
    my ( undef, $el ) = @_;
    return 0 unless $el->isa('PPI::Token');
    return 0 unless $LITERAL{ ref $el };

    # A here-doc's body is not in ->content -- that holds the << marker only.
    my $text = $el->content;
    $text .= join '', $el->heredoc if $el->isa('PPI::Token::HereDoc');

    my @why;
    push @why, 'a literal non-ASCII byte' if $text =~ /[^\x00-\x7f]/;
    push @why, "\\x{$_}"
      for grep { hex($_) > 0x7f } $text =~ /\\x\{([0-9a-fA-F]+)\}/g;
    push @why, "\\x$_"
      for grep { hex($_) > 0x7f } $text =~ /\\x([0-9a-fA-F]{2})/g;
    push @why, '\\N{...}' if $text =~ /\\N\{/;
    return 0 unless @why;

    push @found, {
      line => $el->line_number,
      why  => join( ', ', @why ),
      text => spell($text),
    };
    return 0;
  } );
  return @found;
}

subtest 'the scanner can fail, and leaves prose alone' => sub {
  my $tmp = keep_tempdir();

  my $bad = $tmp->child('Bad.pm');
  $bad->spew_utf8( join '',
    "package Bad;\n",
    "warn \"skip \\x{2014} no board\\n\";\n",
    "1;\n",
  );
  my @found = scan_file($bad);
  is scalar @found, 1, 'an escaped em dash in a message is caught'
    or diag explain \@found;
  is $found[0]{line}, 2, '...on its own line';
  like $found[0]{why}, qr/2014/, '...naming the character';

  my $good = $tmp->child('Good.pm');
  $good->spew_utf8( join '',
    "package Good;\n",
    "# a comment \\x{2014} with an escape\n",
    "\n",
    "=head1 NAME\n",
    "\n",
    "Good \\x{2014} pod prose\n",
    "\n",
    "=cut\n",
    "\n",
    "my \$re = qr/[\\x{80}-\\x{ff}]/;\n",
    "warn \"skip -- no board\\n\";\n",
    "1;\n",
  );
  is scalar( scan_file($good) ), 0,
    'a comment, POD and a character-class regex are not'
    or diag explain [ scan_file($good) ];
};

subtest 'no foundation message carries a non-ASCII character' => sub {
  my @files = sort( 'lib/App/karr/Foundation.pm',
    map { "$_" } path('lib/App/karr/Foundation')->children(qr/\.pm\z/) );
  cmp_ok scalar @files, '>=', 8, 'found the foundation sources to scan'
    or BAIL_OUT('run this from the distribution root');

  my @offenders;
  for my $file (@files) {
    push @offenders, "$file:$_->{line} [$_->{why}] $_->{text}" for scan_file($file);
  }
  is scalar @offenders, 0, 'every message is plain ASCII (ticket #214)'
    or diag(
      "Write it in ASCII: \"--\" says what an em dash says here, and the\n"
      . "message reaches a STDERR that an in-process caller never gave an\n"
      . ":encoding(UTF-8) layer to.\n"
      . join( "\n", map { "  $_" } @offenders )
    );
};

done_testing;
