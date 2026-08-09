use strict;
use warnings;
use Test::More;
use File::Temp qw( tempdir );
use Path::Tiny qw( path );
use Encode qw( encode_utf8 );

use App::karr::Cmd::Skill;

# The bundled skill file is real Markdown prose and legitimately contains
# non-ASCII (em dashes, ellipses, umlauts). _skill_content hands it back
# decoded (slurp_utf8), so `karr skill show` has to encode it before printing.
# Written with \x{} escapes so the expectation does not depend on the source
# encoding of this test file.
my $SKILL_TEXT = "# karr \x{2014} skill\n\nBl\x{00f6}cke \x{2026} \x{00fc}ml\x{00e4}ute\n";

sub run_skill_show {
    my ($share_dir) = @_;

    require File::ShareDir;
    no warnings 'redefine';
    local *File::ShareDir::dist_dir = sub { return $share_dir };

    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, $_[0] };

    open my $capture, '>', \my $out or die "cannot open in-memory handle: $!";
    my $prev = select $capture;
    my $ok   = eval { App::karr::Cmd::Skill->new->execute( ['show'], [] ); 1 };
    my $err  = $@;
    select $prev;
    close $capture;

    die $err unless $ok;
    return ( $out, \@warnings );
}

subtest 'skill show prints UTF-8 bytes without a wide character warning' => sub {
    my $dir = tempdir( CLEANUP => 1 );
    path($dir)->child('claude-skill.md')->spew_utf8($SKILL_TEXT);

    my ( $out, $warnings ) = run_skill_show($dir);

    my @wide = grep { /Wide character/ } @$warnings;
    is( scalar(@wide), 0, 'no "Wide character in print" warning' )
        or diag "warnings emitted: @$warnings";
    is( scalar(@$warnings), 0, 'no warnings at all' )
        or diag "warnings emitted: @$warnings";

    is( $out, encode_utf8($SKILL_TEXT), 'stdout carries the correctly encoded UTF-8 bytes' );
    ok( !utf8::is_utf8($out) || $out !~ /[^\x00-\xff]/,
        'nothing wider than a byte reached the output handle' );
};

subtest '_skill_content stays decoded so check/update comparisons keep working' => sub {
    # Guards the tempting wrong fix of slurping raw: that would silence the
    # warning but make _check/_update compare bytes against slurp_utf8 text
    # (always "outdated") and make _install spew_utf8 a double-encoded file.
    my $dir = tempdir( CLEANUP => 1 );
    path($dir)->child('claude-skill.md')->spew_utf8($SKILL_TEXT);

    require File::ShareDir;
    no warnings 'redefine';
    local *File::ShareDir::dist_dir = sub { return $dir };

    my $content = App::karr::Cmd::Skill->new->_skill_content;

    is( $content, $SKILL_TEXT, '_skill_content returns decoded characters' );
    is( length($content), length($SKILL_TEXT), 'character length matches (not byte-inflated)' );
};

done_testing;
