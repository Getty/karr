#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use lib 't/lib';
use Cwd ();
use lib Cwd::abs_path('lib');
use TestGit qw( require_git_c );
require_git_c();
use TestDenied qw( new_scene run deny allow pushes reset_log refs_dump karr_config can_deny closed_port_url origin_has_refs lines_matching );
use JSON::PP ();

# Ticket k333, parts B/C/E: what a push that cannot land says and leaves
# behind.
#
#  - unreachable remote: three attempts, the change stays in the clone, the
#    success line carries "saved in this clone, not on the remote", and every
#    later command warns (C3) until a `karr sync` lands;
#  - writing commands print their outcome only AFTER the push
#    (sync_after_and_report): a denial takes the change back and leaves no
#    success line, an unreachable remote keeps it with the note.
#
# What a regression would show: "Local refs are intact" style silence, a card
# number missing from the output, a success line printed above a taken-back
# change, a warning only the failing command prints, or one that is on STDOUT.

my $json = JSON::PP->new->canonical;
my $C3_UNPUB = qr/^karr: changes still not on the remote 'origin': (?<what>[^.]*?)\. Last push: remote unreachable \(\d{4}-\d\d-\d\dT\S+\)\. Run 'karr sync' once the remote can be reached\.$/m;

subtest 'unreachable: three attempts, the change stays, the number is printed, later commands warn until sync lands' => sub {
    my $s = new_scene();
    my $url = closed_port_url();
    system( 'git', '-C', $s->{clone}, 'remote', 'set-url', '--push', 'origin', $url ) == 0 or die;

    reset_log($s);
    my $r = run( $s, 'create', 'offline card' );
    is $r->{exit}, 1, 'exit 1';
    is pushes($s), 3, 'three push attempts';
    like $r->{stderr}, qr/Push retry 2 of 3/, 'the retries are announced';
    like $r->{stderr}, qr/Push retry 3 of 3/, 'both of them';
    like $r->{stderr}, qr/^Push failed after 3 attempts: the remote 'origin' \(\Q$url\E\) could not be reached \(.+\)\.$/m,
        'the verdict names the remote, its push URL and that it could not be reached';
    like $r->{stderr}, qr/^Saved in this clone, not on the remote: #1, log, next-id\. Other clones do not see this yet and can hand out the same card number\.$/m,
        'what is only here, and what that risks';
    like $r->{stderr}, qr/^Run 'karr sync' to retry once the remote can be reached\.$/m, 'and the retry advice, which is right for this class';
    unlike $r->{stderr}, qr/Local refs are intact/, 'no reassurance';
    like $r->{stdout}, qr/^Created task 1 \(saved in this clone, not on the remote\): offline card$/m,
        'stdout names the new card number and says it is not on the remote';
    is_deeply [ grep { /^karr\.readonly/ } keys %{ karr_config($s) } ], [], "unreachable is no denial: no read-only state";
    is karr_config($s)->{"karr.lastpushfailure"}, "unreachable", "the failure is remembered for the warning";
    ok !origin_has_refs( $s->{origin}, 'refs/karr/tasks/1' ), 'the card is not on the remote';

    # Later commands warn, on STDERR only.
    $r = run( $s, 'list', '--json' );
    is $r->{exit}, 0, 'list: exit 0';
    like $r->{stderr}, $C3_UNPUB, "C3: the unpublished changes are named on STDERR";
    my $what = $r->{stderr} =~ $C3_UNPUB ? $+{what} : "";
    like $what, qr/#1/, "with the card number";
    like $what, qr/next-id/, "and next-id";
    is lines_matching( $r->{stderr}, qr/changes still not on the remote/ ), 1, 'once';
    my $list = eval { $json->decode( $r->{stdout} ) };
    ok $list, 'stdout stays one parseable JSON document' or diag $r->{stdout};
    like $r->{stdout}, qr/offline card/, 'and carries the card';

    $r = run( $s, 'list', '--quiet' );
    like $r->{stderr}, $C3_UNPUB, '--quiet does not hide it';
    $r = run( $s, 'show', '1' );
    like $r->{stderr}, $C3_UNPUB, 'show carries it too';
    $r = run( $s, 'readonly' );
    like $r->{stderr}, $C3_UNPUB, 'so does karr readonly';

    # The remote is reachable again: sync lands and the warning ends.
    system( 'git', '-C', $s->{clone}, 'config', '--unset', 'remote.origin.pushurl' ) == 0 or die;
    $r = run( $s, 'sync' );
    is $r->{exit}, 0, 'karr sync lands' or diag $r->{stderr};
    ok origin_has_refs( $s->{origin}, 'refs/karr/tasks/1' ), 'the card is on the remote now';
    $r = run( $s, 'list' );
    is $r->{stderr}, '', 'and the next list is silent';
    is_deeply [ grep { /^karr\./ } keys %{ karr_config($s) } ], [], "and the remembered failure is gone from git config";
};

subtest 'a --local-only change is reported on later commands, and a board without a remote is not' => sub {
    my $s = new_scene();
    my $r = run( $s, 'create', 'kept here', '--local-only' );
    is $r->{exit}, 0, '--local-only create: exit 0';
    $r = run( $s, 'list' );
    like $r->{stderr}, qr/^karr: changes still not on the remote 'origin': .*#1/m, 'list names the card that is not on the remote';
    is $r->{stdout} =~ /kept here/ ? 1 : 0, 1, 'stdout is the list as usual';

    # A repository with no remote at all: nothing to be behind.
    my $dir = "$s->{work}/solo";
    mkdir $dir;
    system( 'git', 'init', '-q', $dir ) == 0 or die;
    system( 'git', '-C', $dir, 'config', 'user.email', 'a@karr.test' );
    system( 'git', '-C', $dir, 'config', 'user.name',  'agent-a' );
    my $solo = { clone => $dir };
    is run( $solo, 'init' )->{stderr}, '', 'init without a remote is silent';
    run( $solo, 'create', 'alone' );
    $r = run( $solo, 'list' );
    is $r->{exit}, 0, 'list works';
    is $r->{stderr}, '', 'no remote configured: no warning';
};

# ---------------------------------------------------------------------------
# sync_after_and_report: edit / move / delete
# ---------------------------------------------------------------------------
my @cmds = (
    [ 'edit',   [ 'edit', '1', '-a', 'a note' ],                   qr/^Updated task 1 \(saved in this clone, not on the remote\): seed 1$/m ],
    [ 'move',   [ 'move', '2', 'in-progress', '--claim', 'z' ],    qr/^Moved task 2 \(saved in this clone, not on the remote\): .*in-progress/m ],
    [ 'delete', [ 'delete', '3', '--yes' ],                        qr/^Deleted task 3 \(saved in this clone, not on the remote\): seed 3$/m ],
);

subtest 'unreachable: edit, move and delete print their line with the note' => sub {
    my $s = new_scene( seed => 3 );
    system( 'git', '-C', $s->{clone}, 'remote', 'set-url', '--push', 'origin', closed_port_url() ) == 0 or die;
    for my $c (@cmds) {
        my ( $name, $argv, $line ) = @$c;
        my $r = run( $s, @$argv );
        is $r->{exit}, 1, "$name: exit 1 (the push failed)";
        like $r->{stdout}, $line, "$name: the outcome line is printed, with the note";
        like $r->{stderr}, qr/Push failed after 3 attempts: the remote 'origin'/, "$name: and the failure is said";
    }
    my $r = run( $s, 'edit', '1', '-a', 'json note', '--json' );
    is $r->{exit}, 1, '--json: exit 1';
    my $j = eval { $json->decode( $r->{stdout} ) };
    ok $j, '--json: stdout is still one parseable JSON document' or diag $r->{stdout};
    is $j->{id}, 1, 'about the changed card';
};

SKIP: {
    skip 'running as root: it ignores the read-only mode of the bare repository', 1 unless can_deny();

    subtest 'denied: edit, move and delete print no success line, and the change is gone' => sub {
        my $s = new_scene( seed => 3 );
        deny($s);
        my @patterns = ( 'refs/karr', 'refs/karr-foundation', 'refs/karr-local' );
        my $before = refs_dump( $s->{clone}, @patterns );
        for my $c (@cmds) {
            my ( $name, $argv ) = @$c;
            run( $s, 'readonly', 'off' );    # each command meets the denial itself
            my $r = run( $s, @$argv );
            is $r->{exit}, 1, "$name: exit 1";
            is $r->{stdout}, '', "$name: no success line";
            like $r->{stderr}, qr/^karr: write access to the remote 'origin' \(\Q$s->{origin}\E\) was denied: /m, "$name: C1";
            like $r->{stderr}, qr/Nothing was changed: this command's change was taken back/, "$name: and says it was taken back";
            is refs_dump( $s->{clone}, @patterns ), $before, "$name: refs (tombstones included) as before";
        }
        my $r = run( $s, 'list', '--json' );
        my $cards = $json->decode( $r->{stdout} );
        my $n = ref $cards eq 'ARRAY' ? scalar @$cards : scalar @{ $cards->{tasks} // [] };
        is $n, 3, 'all three cards are still there';
        unlike $r->{stdout}, qr/a note|in-progress/, 'unedited and unmoved';
        allow($s);
    };
}

done_testing;
