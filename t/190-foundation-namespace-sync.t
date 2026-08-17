use strict;
use warnings;
use Test::More;
use lib 't/lib';
use TestGit qw( require_git_c );
require_git_c();
use File::Temp qw( tempdir );
use Cwd qw( abs_path );
use IPC::Open3 qw( open3 );
use Symbol qw( gensym );

use App::karr::Git;
use App::karr::Foundation::ChainStore;

# Ticket #190, work package 6 of the fleet-execution epic (#194). #189 put the
# chain and the run log under refs/karr-foundation/*, where every machine can
# see them -- but nothing carried that namespace to the remote. `karr sync`
# handled refs/karr/* and nothing else, and `karr get-refs` fetches one ref at
# a time, which is fine for a planning blob and useless for a namespace whose
# ref names are minted as it runs.
#
# What is pinned here, and why each is a decision rather than an accident:
#
#   1. One command. `karr sync` carries both namespaces; there is no second
#      command to forget. The implicit per-command sync (sync_before /
#      sync_after on every writing command) stays board-only, which is where
#      the "a stale chain matters less than a stale board" argument is spent.
#   2. Deletions travel as tombstones plus explicit delete refspecs, exactly as
#      the board's do since #178 -- never as a pruning push. Retention
#      (prune_logs) really deletes refs, so a namespace with no publication
#      path for a deletion would re-adopt every pruned run on the next pull.
#   3. A push publishes what this clone did and nothing more: a ref the pusher
#      has never seen stays on the remote. That is #178's lesson, and the fleet
#      namespace is written from more machines than the board is.
#   4. Unpushed local work survives a pull, which is what the mirror is for.
#   5. The fleet namespace has NO wholesale-wipe guard of its own. An empty
#      chain with aged-out logs is a legitimate steady state, and a guard that
#      fires on the normal case is a guard that gets disarmed -- taking the
#      board's --prune along with it. The board's guards run first, in the same
#      command, against the same remote, and that is where the protection is.
#
# Everything runs in throwaway repositories.

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

sub _store {
    my ($dir) = @_;
    return App::karr::Foundation::ChainStore->new(
        git        => App::karr::Git->new( dir => $dir ),
        auto_prune => 0,
    );
}

sub _fleet_refs {
    my ($dir) = @_;
    return [ sort App::karr::Git->new( dir => $dir )
        ->list_refs('refs/karr-foundation/') ];
}

sub _remote_fleet_refs {
    my ($origin) = @_;
    my $out = `git -C '$origin' for-each-ref --format='%(refname)' refs/karr-foundation/`;
    return [ sort grep { length } split /\n/, ( $out // '' ) ];
}

subtest 'karr sync carries the fleet namespace to another clone' => sub {
    my ( $work, $a, $b ) = _clones();

    _karr_ok( $a, 'init the board in clone a', 'init', '--name', 'Fleet' );

    my $chain = _store($a)->write_chain( [
        { id => 1, kind => 'ticket', repo => '/srv/one', ticket => 41 },
        { id => 2, kind => 'plan', needs => [1] },
    ], note => 'planned in a' );
    my $run = _store($a)->new_run_id;
    _store($a)->log_run( $run, event => 'step', step => 1, detail => 'started' );

    _karr_ok( $a, 'sync from clone a', 'sync' );

    is_deeply(
        _remote_fleet_refs("$work/origin.git"),
        [ 'refs/karr-foundation/chain/meta',
          'refs/karr-foundation/chain/step/1',
          'refs/karr-foundation/chain/step/2',
          "refs/karr-foundation/log/$run" ],
        'the push published the whole fleet namespace'
    );

    _karr_ok( $b, 'sync into clone b', 'sync' );

    is( _store($b)->header->{id}, $chain, 'clone b sees the chain header' );
    is_deeply( [ map { $_->{id} } _store($b)->steps ], [ 1, 2 ],
        'clone b sees both steps' );
    is_deeply( [ _store($b)->run_ids ], [$run], 'clone b sees the run log' );
    my @entries = _store($b)->run_entries($run);
    is( scalar @entries, 1, 'the run log entry came across' );
    is( $entries[0]{detail}, 'started', '...with its payload intact' );
};

subtest 'a deletion in the fleet namespace travels, retention included' => sub {
    my ( $work, $a, $b ) = _clones();

    _karr_ok( $a, 'init the board in clone a', 'init', '--name', 'Fleet' );

    my $store = _store($a);
    $store->write_chain( [ { id => 1, kind => 'plan' } ] );
    my $old = '2000-01-01-000000abcdef';
    $store->log_run( $old, event => 'run', detail => 'ancient' );
    my $new = $store->new_run_id;
    $store->log_run( $new, event => 'run', detail => 'today' );

    _karr_ok( $a, 'publish the fleet namespace', 'sync' );
    _karr_ok( $b, 'clone b picks it up', 'sync' );
    is_deeply( [ _store($b)->run_ids ], [ $old, $new ],
        'clone b starts with both runs' );

    my @gone = $store->prune_logs;
    is_deeply( \@gone, [$old], 'retention dropped the ancient run in clone a' );
    is( $store->clear_chain, 2, 'and the chain was cleared in clone a' );

    _karr_ok( $a, 'publish the deletions', 'sync' );
    is_deeply(
        _remote_fleet_refs("$work/origin.git"),
        [ "refs/karr-foundation/log/$new" ],
        'the deletions reached the remote'
    );

    _karr_ok( $b, 'clone b syncs again', 'sync' );
    is_deeply( _fleet_refs($b), [ "refs/karr-foundation/log/$new" ],
        'clone b applied the deletions' );
    ok( !defined _store($b)->header->{id}, 'clone b has no chain left' );
};

subtest 'a push does not take a fleet ref the pusher has never seen' => sub {
    my ( $work, $a, $b ) = _clones();

    _karr_ok( $a, 'init the board in clone a', 'init', '--name', 'Fleet' );
    _store($a)->write_chain( [ { id => 1, kind => 'plan' } ] );
    _karr_ok( $a, 'publish from a', 'sync' );
    _karr_ok( $b, 'clone b picks it up', 'sync' );

    my $brun = _store($b)->new_run_id;
    _store($b)->log_run( $brun, event => 'run', detail => 'from b' );
    _karr_ok( $b, 'clone b publishes its run log', 'sync' );

    # a has never pulled b's run log. A pruning push would take it off the
    # remote, and the mirror update behind it would then make b delete its own
    # copy on the next pull -- #178, one namespace over.
    my $arun = _store($a)->new_run_id;
    _store($a)->log_run( $arun, event => 'run', detail => 'from a' );
    _karr_ok( $a, 'clone a pushes without pulling', 'sync', '--push' );

    my $remote = _remote_fleet_refs("$work/origin.git");
    ok( ( grep { $_ eq "refs/karr-foundation/log/$brun" } @$remote ),
        "b's run log is still on the remote" );
    ok( ( grep { $_ eq "refs/karr-foundation/log/$arun" } @$remote ),
        "a's run log reached the remote" );

    _karr_ok( $b, 'clone b syncs again', 'sync' );
    is_deeply( [ sort( _store($b)->run_ids ) ], [ sort( $arun, $brun ) ],
        'clone b kept its own run and gained the other' );
};

subtest 'a pull keeps fleet work this clone has not pushed yet' => sub {
    my ( $work, $a, $b ) = _clones();

    _karr_ok( $a, 'init the board in clone a', 'init', '--name', 'Fleet' );
    _karr_ok( $a, 'publish the board', 'sync' );
    _karr_ok( $b, 'clone b picks it up', 'sync' );

    my $run = _store($b)->new_run_id;
    _store($b)->log_run( $run, event => 'run', detail => 'unpushed' );

    _karr_ok( $b, 'clone b pulls only', 'sync', '--pull' );
    is_deeply( _fleet_refs($b), [ "refs/karr-foundation/log/$run" ],
        'the unpushed run log survived the pull' );
    is_deeply( _remote_fleet_refs("$work/origin.git"), [],
        '--pull pushed nothing' );
};

subtest 'the fleet namespace may empty out without --prune' => sub {
    my ( $work, $a, $b ) = _clones();

    _karr_ok( $a, 'init the board in clone a', 'init', '--name', 'Fleet' );
    _store($a)->write_chain( [ { id => 1, kind => 'plan' } ] );
    my $run = _store($a)->new_run_id;
    _store($a)->log_run( $run, event => 'run', detail => 'done' );
    _karr_ok( $a, 'publish it', 'sync' );
    _karr_ok( $b, 'clone b picks it up', 'sync' );

    _store($a)->clear_chain;
    App::karr::Git->new( dir => $a )
        ->delete_ref("refs/karr-foundation/log/$run");
    _karr_ok( $a, 'publish the empty namespace', 'sync' );

    # No refusal, no --prune: a finished chain whose logs have aged out is the
    # normal end state, not a catastrophe. The board is untouched and its own
    # wipe guard is still armed.
    my $r = _karr_ok( $b, 'clone b syncs an emptied fleet namespace', 'sync' );
    unlike( $r->{stderr}, qr/refusing to sync/,
        'nothing was refused' );
    is_deeply( _fleet_refs($b), [], 'clone b applied the emptying' );
    my $list = _run( $b, 'list', '--compact' );
    is( $list->{exit}, 0, 'the board in clone b is still there' );
};

subtest 'a fleet deletion whose push failed is published by the next one' => sub {
    my ( $work, $a ) = _clones();
    my $origin = "$work/origin.git";

    _karr_ok( $a, 'init the board in clone a', 'init', '--name', 'Fleet' );
    my $run = _store($a)->new_run_id;
    _store($a)->log_run( $run, event => 'run', detail => 'to be pruned' );
    _karr_ok( $a, 'publish the run log', 'sync' );

    # The remote goes away between the delete and the push. The record of the
    # deletion has to outlive the process that made it, or retention would be
    # local-only forever and the next pull would fetch the pruned run back.
    rename "$work/origin.git", "$work/gone.git" or die "cannot move origin: $!";
    {
        local $ENV{KARR_NO_CLI_FALLBACK} = 1;
        my $git = App::karr::Git->new( dir => $a );
        $git->delete_ref("refs/karr-foundation/log/$run");
        ok( !$git->push_foundation('origin'),
            'the push right after the delete fails' );
        is_deeply( _fleet_refs($a), [], 'the run log is gone locally all the same' );
        is_deeply(
            [ $git->list_refs('refs/karr-local/foundation-deleted/') ],
            ["refs/karr-local/foundation-deleted/log/$run"],
            'and the unpublished deletion is recorded'
        );
    }
    rename "$work/gone.git", "$work/origin.git" or die "cannot restore origin: $!";

    # A new process, as `karr sync` after the failure would be: nothing of the
    # first one's state survives except what is in the refs.
    ok( App::karr::Git->new( dir => $a )->push_foundation('origin'),
        'the retry push lands' );
    is_deeply( _remote_fleet_refs($origin), [],
        'and it publishes the deletion' );
    is_deeply(
        [ App::karr::Git->new( dir => $a )
            ->list_refs('refs/karr-local/foundation-deleted/') ],
        [], 'the settled tombstone is cleared' );
};

subtest 'a repository without a fleet namespace syncs as it always did' => sub {
    my ( $work, $a, $b ) = _clones();

    _karr_ok( $a, 'init the board in clone a', 'init', '--name', 'Plain' );
    _karr_ok( $a, 'create a card', 'create', 'Only a board here' );
    my $r = _karr_ok( $a, 'sync with nothing under refs/karr-foundation/', 'sync' );
    like( $r->{stdout}, qr/^Done\.$/m, 'the sync ran to the end' );
    is_deeply( _remote_fleet_refs("$work/origin.git"), [],
        'and invented no fleet refs' );

    _karr_ok( $b, 'clone b syncs', 'sync' );
    my $list = _karr_ok( $b, 'clone b has the board', 'list', '--compact' );
    like( $list->{stdout}, qr/Only a board here/, '...with the card on it' );
};

done_testing;
