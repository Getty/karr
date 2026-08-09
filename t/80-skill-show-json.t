use strict;
use warnings;
use Test::More;
use File::Temp qw( tempdir );
use Path::Tiny qw( path );
use Encode qw( encode_utf8 );
use JSON::MaybeXS qw( decode_json );
use App::karr::Cmd::Skill;

# Ticket #79: `karr skill show --json` printed the raw skill Markdown, byte for
# byte identical to `karr skill show`, so the output was not JSON at all
# (probed pre-fix: `diff <(karr skill show) <(karr skill show --json)` empty,
# decode_json on it dies "malformed number ... before '---\nname: karr'").
# Its siblings `skill check --json` / `skill install --json` were already
# correct, so only this one action ignored the flag.
#
# The second half of this file guards the UTF-8 boundary (ticket #33, commit
# 259da71): _skill_content hands back decoded characters and the plain branch
# encodes them at its single print site, so the JSON branch must let
# Role::Output::print_json do the encoding and must not encode as well.

my $SKILL_TEXT = "# karr \x{2014} skill\n\nBl\x{00f6}cke \x{2026} \x{00fc}ml\x{00e4}ute\n";

sub run_skill_show {
    my (@argv_opts) = @_;
    my $dir = tempdir( CLEANUP => 1 );
    path($dir)->child('claude-skill.md')->spew_utf8($SKILL_TEXT);

    require File::ShareDir;
    no warnings 'redefine';
    local *File::ShareDir::dist_dir = sub { return $dir };

    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, $_[0] };

    open my $capture, '>', \my $out or die "cannot open in-memory handle: $!";
    my $prev = select $capture;
    my $ok   = eval {
        App::karr::Cmd::Skill->new(@argv_opts)->execute( ['show'], [] );
        1;
    };
    my $err = $@;
    select $prev;
    close $capture;
    die $err unless $ok;

    return ( $out, \@warnings );
}

subtest 'skill show --json emits JSON, not raw Markdown' => sub {
    my ( $out, $warnings ) = run_skill_show( json => 1 );

    unlike $out, qr/\A---\nname: karr/,
        'the payload no longer starts with the raw skill frontmatter';

    my $data = eval { decode_json($out) };
    ok !$@, 'the payload parses as JSON' or diag "decode_json said: $@\nraw: $out";
    is ref($data), 'HASH', 'it is a JSON object';
    is_deeply [ sort keys %$data ], ['content'], 'with a single "content" key';
    is scalar(@$warnings), 0, 'no warnings emitted' or diag "@$warnings";
};

subtest 'the JSON payload carries the skill content, encoded exactly once' => sub {
    my ($json_out) = run_skill_show( json => 1 );
    my ($plain_out) = run_skill_show();

    my $data = decode_json($json_out);

    is $data->{content}, $SKILL_TEXT,
        'the decoded content is the skill text, character for character';
    is encode_utf8( $data->{content} ), $plain_out,
        'and re-encoding it reproduces the plain-output bytes byte for byte';

    # The specific failure a second encode_utf8 in the JSON branch would cause:
    # every non-ASCII character would come back as its UTF-8 bytes read as
    # Latin-1 (an em dash as "\x{e2}\x{80}\x{94}").
    unlike $data->{content}, qr/\x{00e2}\x{0080}\x{0094}/,
        'the em dash did not survive as double-encoded bytes';
};

subtest 'plain skill show is unchanged by the --json branch' => sub {
    my ( $out, $warnings ) = run_skill_show();
    is $out, encode_utf8($SKILL_TEXT), 'stdout still carries the raw UTF-8 bytes';
    my @wide = grep { /Wide character/ } @$warnings;
    is scalar(@wide), 0, 'still no "Wide character in print" warning'
        or diag "@$warnings";
};

done_testing;
