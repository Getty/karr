#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use lib 't/lib';
use Cwd ();
use lib Cwd::abs_path('lib');
use TestGit qw( require_git_c );
require_git_c();
use TestDenied qw( new_scene run deny allow pushes reset_log refs_dump karr_config can_deny lines_matching origin_has_refs );
use JSON::PP ();

# Ticket k333, parts B/C/E: `karr readonly` in its three states, the lasting
# warning on read commands (C3), and the `on` mode.
#
# What a regression would show: a state the command cannot report or set, a
# warning on stdout (or one that --quiet hides, or one printed twice), a
# `--json` payload that is not the same with and without the state, a usage
# error followed by a warning, or `on` that does not refuse writes / lets a
# read complain.

my $C3_DENIED = qr/^karr: this clone cannot write the board: write access to 'origin' was denied on \d{4}-\d\d-\d\dT\S+\. Fix the access, or 'karr readonly on' if this clone is only for reading\.$/m;
my $json = JSON::PP->new->canonical;

# -------- off: needs no denying origin, so it runs for root too ----------
my $s = new_scene( seed => 2 );
my $clone = $s->{clone};

subtest 'karr readonly in a clone that may write: off' => sub {
    my $r = run( $s, 'readonly' );
    is $r->{exit}, 0, 'exit 0';
    like $r->{stdout}, qr/^Read-only: off -- this clone writes the board and pushes it to 'origin'/, 'says off';
    is $r->{stderr}, '', 'nothing on STDERR';

    $r = run( $s, 'readonly', '--json' );
    is $r->{exit}, 0, '--json: exit 0';
    my $j = eval { $json->decode( $r->{stdout} ) };
    ok $j, '--json prints one JSON object' or diag $r->{stdout};
    is $j->{mode}, 'off', 'mode off';
    is $r->{stderr}, '', 'nothing on STDERR';
};

my $list_before_json = run( $s, 'list', '--json' );
is $list_before_json->{exit}, 0, 'list --json in the clean clone works';
my $list_before_plain = run( $s, 'list' );

# -------- on ----------
subtest 'karr readonly on: reads are silent, writes are refused with the one line, off pushes again' => sub {
    my $r = run( $s, 'readonly', 'on' );
    is $r->{exit}, 0, 'on: exit 0';
    like $r->{stdout}, qr/^Read-only: on -- set by hand/, 'says on';
    my $since = ( $r->{stdout} =~ /Since:\s+(\S+)/ )[0];
    ok defined $since, 'with a time';

    my $j = $json->decode( run( $s, 'readonly', '--json' )->{stdout} );
    is $j->{mode}, 'on', '--json: mode on';
    ok $j->{applies}, 'and it applies to the push URL of the remote';
    is $j->{push_url}, $s->{origin}, 'which is recorded';

    $r = run( $s, 'readonly', 'on' );
    like $r->{stdout}, qr/Since:\s+\Q$since\E/, 'on again confirms and keeps its time';

    for my $cmd ( [ 'list' ], [ 'list', '--json' ], [ 'show', '1' ], [ 'board' ] ) {
        $r = run( $s, @$cmd );
        is $r->{exit}, 0, "@$cmd: exit 0";
        is $r->{stderr}, '', "@$cmd: silent on STDERR in on mode";
    }

    reset_log($s);
    my $before = refs_dump($clone);
    $r = run( $s, 'create', 'refused' );
    is $r->{exit}, 1, 'create: exit 1';
    is $r->{stderr}, "karr: this clone is read-only for the board (karr readonly on). Nothing was changed.\n",
        'exactly the one line';
    is $r->{stdout}, '', 'no stdout';
    is pushes($s), 0, 'no push';
    is refs_dump($clone), $before, 'nothing written';

    $r = run( $s, 'create', 'refused', '--local-only' );
    is $r->{exit}, 1, '--local-only refused too';
    is $r->{stderr}, "karr: this clone is read-only for the board (karr readonly on). Nothing was changed.\n", 'with the same line';

    $r = run( $s, 'readonly', 'off' );
    is $r->{exit}, 0, 'off: exit 0';
    like $r->{stdout}, qr/no longer read-only/, 'says so';
    is_deeply karr_config($s), {}, 'the git config keys are gone';

    reset_log($s);
    $r = run( $s, 'create', 'after off' );
    is $r->{exit}, 0, 'the next write goes through';
    like $r->{stdout}, qr/^Created task \d+: after off$/m, 'with the plain success line';
    is $r->{stderr}, '', 'and nothing on STDERR';
    is pushes($s), 1, 'it pushed';
    ok origin_has_refs( $s->{origin}, 'refs/karr/tasks/3' ), 'the card is on the remote';
};

# -------- usage errors ----------
subtest 'karr readonly: usage errors exit 2 and print no lasting warning' => sub {
    run( $s, 'readonly', 'on' );    # a state that would warn on a read, were it denied
    for my $argv ( [ 'bogus' ], [ 'on', 'extra' ], [ 'sideways' ] ) {
        my $r = run( $s, 'readonly', @$argv );
        is $r->{exit}, 2, "readonly @$argv: exit 2";
        like $r->{stderr}, qr/Usage error|unknown argument|unexpected extra argument/i, 'says what is wrong';
        unlike $r->{stderr}, qr/changes still not on the remote|cannot write the board/, 'no lasting warning after a usage error';
    }
    run( $s, 'readonly', 'off' );
};

# -------- denied ----------
SKIP: {
    skip 'running as root: it ignores the read-only mode of the bare repository', 4 unless can_deny();

    my $d = new_scene( seed => 1 );
    my $dclone = $d->{clone};
    my $baseline_json  = run( $d, 'list', '--json' );
    my $baseline_plain = run( $d, 'list' );
    is $baseline_json->{stderr}, '', 'baseline: list is silent before the denial';

    deny($d);
    my $c = run( $d, 'create', 'probe' );
    is $c->{exit}, 1, 'the denial is learned (create refused by the remote)';

    subtest 'karr readonly in denied' => sub {
        my $r = run( $d, 'readonly' );
        is $r->{exit}, 0, 'exit 0';
        like $r->{stdout}, qr/^Read-only: denied -- the remote denied this clone write access/, 'says denied';
        like $r->{stdout}, qr/^  Remote: origin \(\Q$d->{origin}\E\)$/m, 'which remote and push URL';
        like $r->{stdout}, qr/^  Since:  \d{4}-\d\d-\d\dT\S+$/m, 'since when';
        like $r->{stdout}, qr/^  Reason: this user cannot write the remote repository's files$/m, 'why';
        like $r->{stdout}, qr/karr readonly on\./, 'and the way out';

        $r = run( $d, 'readonly', '--json' );
        my $j = eval { $json->decode( $r->{stdout} ) };
        ok $j, '--json parses' or diag $r->{stdout};
        is $j->{mode}, 'denied', 'mode';
        is $j->{push_url}, $d->{origin}, 'push_url';
        is $j->{current_push_url}, $d->{origin}, 'current_push_url';
        ok $j->{applies}, 'applies';
        like $j->{since}, qr/^\d{4}-/, 'since';
        like $j->{reason}, qr/cannot write/, 'reason';
    };

    subtest 'list warns on STDERR (C3), its JSON stdout is unchanged' => sub {
        my $r = run( $d, 'list', '--json' );
        is $r->{exit}, 0, 'exit 0';
        like $r->{stderr}, $C3_DENIED, 'the denied warning on STDERR';
        is lines_matching( $r->{stderr}, qr/this clone cannot write the board/ ), 1, 'printed once';
        my $now  = eval { $json->decode( $r->{stdout} ) };
        my $then = $json->decode( $baseline_json->{stdout} );
        ok $now, 'stdout is still one parseable JSON document' or diag $r->{stdout};
        is_deeply $now, $then, 'and equals the output without the state';
        is $r->{stdout}, $baseline_json->{stdout}, 'byte for byte';

        $r = run( $d, 'list' );
        is $r->{stdout}, $baseline_plain->{stdout}, 'plain list: stdout unchanged too';
        like $r->{stderr}, $C3_DENIED, 'and the warning is on STDERR';

        $r = run( $d, 'list', '--quiet' );
        like $r->{stderr}, $C3_DENIED, '--quiet does not hide it';
        $r = run( $d, 'show', '1' );
        like $r->{stderr}, $C3_DENIED, 'any read command carries it: show';
    };

    subtest 'readonly on in a denied clone: the state becomes on, reads go silent' => sub {
        my $r = run( $d, 'readonly', 'on' );
        is $r->{exit}, 0, 'exit 0';
        like $r->{stdout}, qr/^Read-only: on -- set by hand/, 'now on';
        $r = run( $d, 'list' );
        is $r->{stderr}, '', 'a read in on mode prints no warning';
        $r = run( $d, 'create', 'x' );
        is $r->{stderr}, "karr: this clone is read-only for the board (karr readonly on). Nothing was changed.\n", 'and a write gets the one `on` line';
    };

    subtest 'usage error in a denied clone: no warning after it' => sub {
        run( $d, 'readonly', 'off' );
        run( $d, 'create', 'probe again' );    # learn denied again
        is karr_config($d)->{'karr.readonly'}, 'denied', 'precondition: denied';
        my $r = run( $d, 'readonly', 'bogus' );
        is $r->{exit}, 2, 'exit 2';
        unlike $r->{stderr}, qr/cannot write the board/, 'no denied warning after a usage error';
        $r = run( $d, 'list', '--no-such-option' );
        is $r->{exit}, 2, 'a usage error of another command: exit 2';
        unlike $r->{stderr}, qr/cannot write the board/, 'no denied warning there either';
    };

    subtest 'readonly off in denied: the next write tries to push and learns denied again' => sub {
        my $r = run( $d, 'readonly', 'off' );
        is $r->{exit}, 0, 'off: exit 0';
        like $r->{stdout}, qr/no longer read-only/, 'says so';
        like $r->{stdout}, qr/read-only again/, 'and that a still-denied remote brings it back';
        is_deeply karr_config($d), {}, 'state cleared';
        reset_log($d);
        $r = run( $d, 'create', 'try' );
        is $r->{exit}, 1, 'exit 1';
        like $r->{stderr}, qr/^karr: write access to the remote 'origin' .* was denied: /m, 'C1 again (the push was attempted)';
        is pushes($d), 1, 'one push';
        is karr_config($d)->{'karr.readonly'}, 'denied', 'denied again';
    };

    allow($d);
}

done_testing;
