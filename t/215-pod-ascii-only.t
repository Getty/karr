use strict;
use warnings;
use Test::More;
use Path::Tiny;
use PPI;

# Ticket #215: no non-ASCII character in POD, or in a `# ABSTRACT` line, under
# lib/ or bin/.
#
# t/124-source-ascii-only.t polices executable code and exempts POD and
# comments on purpose -- they are prose, not output, and full of em dashes
# that were fine to leave. That stayed true for comments (never rendered) but
# not for POD: PodWeaver does add `=encoding UTF-8` to every file it weaves
# (confirmed against a built dist, so podchecker's "Non-ASCII character seen
# before =encoding" warning on the bare source was a false alarm, not the
# actual bug), yet the maintainer's call is to keep POD itself plain ASCII
# regardless -- there are hundreds of interfaces that render it, and not all
# of them handle UTF-8 equally well. `# ABSTRACT` is POD too: PodWeaver weaves
# it straight into the NAME section.
#
# So this test closes exactly the gap t/124 leaves open on purpose: POD and
# `# ABSTRACT`, nothing else. A plain `#` comment or a string literal with an
# em dash is still fine -- t/124 and t/214-foundation-ascii-messages.t already
# police (or deliberately don't police) those.

# Locations where a non-ASCII character in POD/`# ABSTRACT` is content, not
# prose, and must not be flattened to an ASCII lookalike -- e.g. a
# character-encoding walkthrough that has to show a real byte, not a
# description of one. Keyed by "file:line" from PPI's ->line_number.
#
# Empty right now: the #215 sweep found only prose punctuation (65 em dashes,
# two ellipses, one arrow, one multiplication sign), all of it replaceable
# with "--", "...", "->" and "x" respectively -- including in Encoding.pm and
# Cmd/Repair.pm, the two files that talk about character encoding and were
# checked most closely for exactly this possibility. Both use `C<"\x{fc}ber">`
# style escapes to show bytes, never a literal non-ASCII character, so nothing
# there qualified.
my %EXEMPT = (
  # 'lib/App/karr/Encoding.pm:123' => 'reason the character itself is content',
);

# Every non-ASCII character on its own line inside a PPI::Token::Pod, or a
# `# ABSTRACT:` PPI::Token::Comment, in $file.
sub scan_file {
  my ($file) = @_;
  my $doc = PPI::Document->new("$file")
    or die "PPI could not parse $file: " . PPI::Document->errstr . "\n";
  my @found;
  $doc->find( sub {
    my ( undef, $el ) = @_;
    my $is_pod      = $el->isa('PPI::Token::Pod');
    my $is_abstract = $el->isa('PPI::Token::Comment')
      && $el->content =~ /^#\s*ABSTRACT:/;
    return 0 unless $is_pod || $is_abstract;

    my $start = $el->line_number;
    my @lines = split /\n/, $el->content, -1;
    for my $i ( 0 .. $#lines ) {
      next unless $lines[$i] =~ /[^\x00-\x7f]/;
      push @found, {
        line => $start + $i,
        kind => $is_abstract ? 'ABSTRACT' : 'POD',
        text => $lines[$i],
      };
    }
    return 0;
  } );
  return @found;
}

# Render a finding with the offending bytes spelled out, so a failure names
# the character to replace instead of printing mojibake back at the reader.
sub describe {
  my ( $file, $f ) = @_;
  ( my $shown = $f->{text} ) =~ s/([^\x20-\x7e])/sprintf '<%02x>', ord $1/ge;
  return sprintf '%s:%s [%s] %s', $file, $f->{line}, $f->{kind}, $shown;
}

# --------------------------------------------------------------------------
# The scanner has to be able to fail, and has to leave everything else alone.
# Both are proven against fixtures before it is pointed at the distribution:
# a green result below is only worth having if these two subtests pass.
# --------------------------------------------------------------------------

my $tmp = Path::Tiny->tempdir;

subtest 'the scanner catches non-ASCII in POD and # ABSTRACT' => sub {
  # "\xe2\x80\x94" is the em dash written as the three separate Latin-1 bytes
  # a source file without `use utf8` actually holds.
  my $bad = $tmp->child('Bad.pm');
  $bad->spew_raw( join '',
    "# ABSTRACT: does a thing \xe2\x80\x94 badly\n",
    "package Bad;\n",
    "\n",
    "=head1 DESCRIPTION\n",
    "\n",
    "Prose with an em dash \xe2\x80\x94 right here.\n",
    "\n",
    "=cut\n",
    "\n",
    "1;\n",
  );

  my @found = scan_file($bad);
  is( scalar @found, 2, 'both the ABSTRACT line and the POD prose are caught' )
    or diag( join "\n", map { describe( $bad, $_ ) } @found );
  is $found[0]{line}, 1, 'the ABSTRACT line is reported on its own line';
  is $found[0]{kind}, 'ABSTRACT', '...and identified as the ABSTRACT comment';
  is $found[1]{kind}, 'POD', 'the POD prose is identified as POD';
};

subtest 'the scanner leaves comments and string literals alone' => sub {
  my $good = $tmp->child('Good.pm');
  $good->spew_raw( join '',
    "# ABSTRACT: does a thing\n",
    "package Good;\n",
    "\n",
    "# a plain comment with an em dash \xe2\x80\x94 stays as it is\n",
    "my \$msg = \"a string literal with an em dash \xe2\x80\x94 too\";\n",
    "\n",
    "=head1 DESCRIPTION\n",
    "\n",
    "Plain ASCII prose, nothing to report.\n",
    "\n",
    "=cut\n",
    "\n",
    "1;\n",
  );

  # Guard against a vacuous pass: if the fixture lost its non-ASCII bytes the
  # subtest below would succeed while proving nothing.
  like $good->slurp_raw, qr/[^\x00-\x7f]/,
    'the fixture really does carry non-ASCII bytes';

  my @found = scan_file($good);
  is( scalar @found, 0, 'none of them are reported' )
    or diag( join "\n", map { describe( $good, $_ ) } @found );
};

# --------------------------------------------------------------------------
# The distribution itself.
# --------------------------------------------------------------------------

my @files;
path('lib')->visit(
  sub { my ($p) = @_; push @files, "$p" if $p->is_file && $p =~ /\.pm\z/ },
  { recurse => 1 },
);
push @files, map { "$_" } grep { $_->is_file } path('bin')->children;
@files = sort @files;

cmp_ok scalar @files, '>=', 2, 'found source files to scan'
  or BAIL_OUT('nothing to scan -- run this from the distribution root');
ok scalar( grep { m{lib/App/karr/Encoding\.pm\z} } @files ),
  'the sweep reaches lib/App/karr/Encoding.pm';
ok scalar( grep { m{bin/karr-foundation\z} } @files ),
  'the sweep reaches bin/karr-foundation';

my @offenders;
for my $file (@files) {
  for my $f ( scan_file($file) ) {
    next if $EXEMPT{"$file:$f->{line}"};
    push @offenders, describe( $file, $f );
  }
}

is scalar @offenders, 0,
  'no non-ASCII in POD or # ABSTRACT under lib/ and bin/ (ticket #215)'
  or diag(
    "Non-ASCII in POD renders inconsistently across the many interfaces that\n"
    . "show it -- replace with the ASCII equivalent (em dash -> '--', ellipsis\n"
    . "-> '...', arrow -> '->', multiplication sign -> 'x'), or add a reasoned\n"
    . "entry to %EXEMPT above if the character itself is the content.\n"
    . join( "\n", map { "  $_" } @offenders )
  );

done_testing;
