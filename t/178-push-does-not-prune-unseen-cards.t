use strict;
use warnings;
use Test::More;
use lib 't/lib';
use TestGit qw( require_git_c );
require_git_c();
use File::Temp qw( tempdir );
use File::Path qw( make_path );
use Cwd qw( abs_path );
use IPC::Open3 qw( open3 );
use Symbol qw( gensym );
use App::karr::Git;
use App::karr::BoardStore;

# Ticket #178: a `karr create` that reported success could be gone from the
# board a moment later -- not just from the remote, from the clone that made
# it. Eight parallel creates in one clone lost a whole card in 2 of 20 runs.
#
# The race was not needed to lose one. Every push used to send the board under
# a forced, *pruning* refspec, and prune says "the refs I have are the whole
# namespace" -- a claim no clone is in a position to make. A card another clone
# created and this one has never pulled is a ref this one does not have, so the
# push deleted it off the remote. _mirror_local_state then made the mirror
# agree, and on the clone that owned the card the next pull read it as
# "L == T, R gone" -- the branch for a card the remote deliberately deleted,
# which is silent by design -- and removed it locally too. Card gone from the
# remote, gone from its own clone, never seen by the clone that pushed.
#
# So the first subtest below needs no concurrency at all: one `karr sync
# --push` from a clone that had not pulled was enough.
#
# The fix is that a routine push publishes only what this clone actually did:
# its own refs, plus a delete refspec for every board ref it deleted itself,
# recorded as a tombstone under refs/karr-local/deleted/ so the record outlives
# the process that made it. The other two subtests pin what must not be lost
# along with prune -- deletions still propagate, and one that could not be
# pushed still gets published later.

my $ROOT = abs_path('.');
my $BIN  = "$ROOT/bin/karr";

sub _run {
    my ( $dir, @argv ) = @_;
    my $err = gensym;
    my $pid = open3( my $in, my $out, $err,
        $^X, "-I$ROOT/lib", $BIN, '--dir', $dir, @argv );
    close $in;
    my $stdout = do { local $/; <$out> };
    my $stderr = do { local $/; <$err> };
    waitpid $pid, 0;
    return {
        exit   => $? >> 8,
        stdout => defined $stdout ? $stdout : '',
        stderr => defined $stderr ? $stderr : '',
    };
}

sub _karr_ok {
    my ( $dir, $what, @argv ) = @_;
    my $r = _run( $dir, @argv );
    is( $r->{exit}, 0, $what ) or diag "stdout: $r->{stdout}\nstderr: $r->{stderr}";
    return $r;
}

# A bare origin and two clones of it, each with a git identity of its own.
sub _clones {
    my $work = tempdir( CLEANUP => 1 );
    system( 'git', 'init', '-q', '--bare', "$work/origin.git" ) == 0
        or die "cannot create origin";
    for my $name (qw( a b )) {
        system("git clone -q '$work/origin.git' '$work/$name' 2>/dev/null") == 0
            or die "cannot clone $name";
        system( 'git', '-C', "$work/$name", 'config', 'user.email',
            "$name\@karr.test" ) == 0 or die;
        system( 'git', '-C', "$work/$name", 'config', 'user.name',
            "agent-$name" ) == 0 or die;
    }
    return ( $work, "$work/a", "$work/b" );
}

sub _task_ids {
    my ($dir) = @_;
    return [ sort { $a <=> $b } App::karr::Git->new( dir => $dir )->list_task_refs ];
}

subtest 'a push does not take a card the pusher has never seen off the remote' => sub {
    my ( $work, $a, $b ) = _clones();
    my $origin = "$work/origin.git";

    _karr_ok( $a, 'init in clone a', 'init', '--name', 'Unpruned' );
    _karr_ok( $a, 'clone a publishes the board', 'sync', '--quiet' );
    _karr_ok( $b, 'clone b adopts the board', 'sync', '--pull', '--quiet' );

    my $created = _karr_ok( $b, 'clone b creates a card', 'create', 'B card' );
    like( $created->{stdout}, qr/^Created task 1: B card$/m, 'the create reported success' );
    is_deeply( _task_ids($origin), [1], 'and the card is on the remote' );
    is_deeply( _task_ids($a), [], 'clone a has never seen that card' );

    # The push that used to destroy it. Nothing exotic: a clone whose board is
    # older than the remote's publishing what it has.
    _karr_ok( $a, 'clone a pushes without pulling first', 'sync', '--push', '--quiet' );
    is_deeply( _task_ids($origin), [1],
        "the push left the other clone's card on the remote" );

    # And the half that made it a total loss: b's own copy read the pruned
    # remote as a deletion and deleted itself.
    _karr_ok( $b, 'clone b syncs', 'sync', '--quiet' );
    is_deeply( _task_ids($b), [1], 'clone b still has the card it created' );
    like( _run( $b, 'show', 1 )->{stdout}, qr/B card/, 'and the card still reads back' );

    _karr_ok( $a, 'clone a pulls', 'sync', '--quiet' );
    is_deeply( _task_ids($a), [1], 'clone a converges on it the ordinary way' );
};

subtest 'a deletion still reaches the remote and the other clone' => sub {
    my ( $work, $a, $b ) = _clones();
    my $origin = "$work/origin.git";

    _karr_ok( $a, 'init in clone a', 'init', '--name', 'Unpruned' );
    _karr_ok( $a, 'create task 1', 'create', 'A1' );
    _karr_ok( $a, 'create task 2', 'create', 'A2' );
    _karr_ok( $b, 'clone b adopts the board', 'sync', '--pull', '--quiet' );
    is_deeply( _task_ids($b), [ 1, 2 ], 'both clones hold both cards' );

    _karr_ok( $b, 'clone b deletes task 2', 'delete', 2, '--yes' );
    is_deeply( _task_ids($origin), [1], 'the deletion reached the remote' );
    ok( !App::karr::Git->new( dir => $b )->list_refs('refs/karr-local/deleted/'),
        'and the tombstone that carried it was cleared by the push' );

    _karr_ok( $a, 'clone a syncs', 'sync', '--quiet' );
    is_deeply( _task_ids($a), [1], 'so the card is gone in the other clone too' );
};

subtest 'a deletion whose push failed is published by the next one' => sub {
    my ( $work, $a ) = _clones();
    my $origin = "$work/origin.git";

    _karr_ok( $a, 'init in clone a', 'init', '--name', 'Unpruned' );
    _karr_ok( $a, 'create task 1', 'create', 'A1' );
    _karr_ok( $a, 'create task 2', 'create', 'A2' );
    is_deeply( _task_ids($origin), [ 1, 2 ], 'both cards are on the remote' );

    # The remote goes away between the delete and the push, which is what the
    # sync guard's "Local refs are intact. Run 'karr sync' to retry." promises
    # to be recoverable. prune used to make good on that by accident: it
    # re-derived every deletion from the local refs on any later push. The
    # tombstone is what makes it deliberate.
    rename "$work/origin.git", "$work/gone.git" or die "cannot move origin: $!";
    {
        local $ENV{KARR_NO_CLI_FALLBACK} = 1;
        my $git = App::karr::Git->new( dir => $a );
        App::karr::BoardStore->new( git => $git )->delete_task(2);
        ok( !$git->push('origin'), 'the push right after the delete fails' );
        is_deeply( _task_ids($a), [1], 'the card is deleted locally all the same' );
        is_deeply(
            [ $git->list_refs('refs/karr-local/deleted/') ],
            ['refs/karr-local/deleted/tasks/2/data'],
            'and the unpublished deletion is recorded'
        );
    }
    rename "$work/gone.git", "$work/origin.git" or die "cannot restore origin: $!";

    # A new process, as `karr sync` after the failure would be: nothing of the
    # first one's state is left except what is in the refs.
    ok( App::karr::Git->new( dir => $a )->push('origin'), 'the retry push lands' );
    is_deeply( _task_ids($origin), [1], 'and it publishes the deletion' );
};

subtest 'a repository with no remote settles its tombstones instead of hoarding them' => sub {
    # Ticket #197: push returns before anything else when no remote is
    # configured, so _clear_pending_deletes never ran there and every deletion
    # left a ref under refs/karr-local/deleted/ for good -- one per deleted
    # card, each holding that card's commit reachable, and all of them queued
    # for a push that had not happened yet.
    my $solo = tempdir( CLEANUP => 1 );
    system( 'git', 'init', '-q', $solo ) == 0 or die "cannot init $solo";
    system( 'git', '-C', $solo, 'config', 'user.email', 'solo@karr.test' ) == 0
        or die;
    system( 'git', '-C', $solo, 'config', 'user.name', 'agent-solo' ) == 0
        or die;

    _karr_ok( $solo, 'init without a remote', 'init', '--name', 'Solo' );
    _karr_ok( $solo, 'create task 1',         'create', 'S1' );
    _karr_ok( $solo, 'create task 2',         'create', 'S2' );
    _karr_ok( $solo, 'delete task 1', 'delete', 1, '--yes' );
    _karr_ok( $solo, 'delete task 2', 'delete', 2, '--yes' );

    my $git = App::karr::Git->new( dir => $solo );
    is_deeply( [ $git->list_refs('refs/karr-local/deleted/') ],
        [], 'no tombstone survives a push that had nothing to publish to' );
    is_deeply( _task_ids($solo), [], 'and the cards really are deleted' );
    ok( !$git->has_pending_deletes,
        'so the auto-fetch guard (#173) reads "nothing unpublished" too' );

    # Why it matters that they are settled rather than kept: a remote added
    # later inherits the whole backlog, and a push checks no board identity
    # (#95 guards the pull), so a board that happens to have cards at the same
    # paths loses them to deletions made in a repository that never saw it.
    my ( $work, $a ) = _clones();
    my $origin = "$work/origin.git";
    _karr_ok( $a, 'a board exists elsewhere', 'init', '--name', 'Shared' );
    _karr_ok( $a, 'with a card at tasks/1',   'create', 'A1' );
    is_deeply( _task_ids($origin), [1], 'and that card is on the remote' );

    system( 'git', '-C', $solo, 'remote', 'add', 'origin', $origin ) == 0
        or die "cannot add remote";
    _karr_ok( $solo, 'the solo repository gets a remote and pushes',
        'sync', '--push', '--quiet' );
    is_deeply( _task_ids($origin), [1],
        "the other board's card is still there" );
};

done_testing;
