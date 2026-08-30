use strict;
use warnings;
use Test::More;
use lib 't/lib';
use TestGit qw( require_git_c );
require_git_c();
use TestKarr qw( run_karr );
use Config;
use File::Temp qw( tempdir );
use Path::Tiny qw( path );
use POSIX ();
use Time::HiRes ();

use App::karr::Git;
use App::karr::Foundation::ChainStore;

# Ticket #189, work package 5 of the fleet-execution epic (#194): the chain and
# the run log are COORDINATION, so they live in git refs where every machine
# sees them, under refs/karr-foundation/*. Execution -- which agent command
# exists here, whether it currently works -- stayed local with #188 and does not
# appear anywhere below.
#
# What is pinned here, and why each is a decision rather than an accident:
#
#   1. A step names no agent. Naming one would tie shared state to a machine,
#      so the store refuses the key instead of ignoring it.
#   2. The chain is a DAG. Steps with no edge between them are ready at the
#      same time; the planner expresses parallelism by leaving edges out, and a
#      cycle is refused at write time rather than discovered as a chain that
#      silently never moves.
#   3. A step whose precheck no longer holds is marked stale, not executed --
#      and an unanswerable precheck counts as not holding, because that costs a
#      planning round while the other direction costs whatever the step does.
#   4. Step updates are compare-and-swap, on the board's own machinery, so two
#      overlapping foundation ticks cannot both claim one step.
#   5. Run logs are one ref per run, segmented at a cap the way the activity log
#      is (#171), and retention bounds the namespace by age AND by count.
#   6. `karr set-refs` may no longer write the structured subtrees, while
#      `karr get-refs` may still read them.
#
# Everything runs in throwaway repositories.

sub init_repo {
    my $repo = tempdir( CLEANUP => 1 );
    system( 'git', 'init', '-q', $repo ) == 0 or BAIL_OUT('git init failed');
    system( 'git', '-C', $repo, 'config', 'user.email', 'fleet@example.com' ) == 0
        or BAIL_OUT('git config failed');
    system( 'git', '-C', $repo, 'config', 'user.name', 'Fleet' ) == 0
        or BAIL_OUT('git config failed');
    return $repo;
}

sub mk_store {
    my ( $repo, %arg ) = @_;
    return App::karr::Foundation::ChainStore->new(
        git => App::karr::Git->new( dir => "$repo" ), %arg );
}

sub refs_under {
    my ( $repo, $prefix ) = @_;
    my @refs = sort( split /\n/,
        `git -C '$repo' for-each-ref --format='%(refname)' '$prefix'` );
    return @refs;
}

sub ids_of { return [ map { $_->{id} } @_ ] }

sub err_of {
    my ( $code ) = @_;
    my $err = '';
    eval { $code->(); 1 } or $err = $@;
    return $err;
}


# ---------------------------------------------------------------------------

subtest 'the chain lives in refs/karr-foundation and a step names no agent' => sub {
    my $repo  = init_repo();
    my $store = mk_store($repo);

    my $chain_id = $store->write_chain(
        [
            {   id       => 1,
                kind     => 'ticket',
                repo     => "$repo",
                ticket   => 41,
                timeout  => 1800,
                precheck => 'ticket_status == todo',
                on_stall => 'plan',
                on_rate_limit => 'requeue',
            },
            { id => 2, kind => 'shell',    repo => "$repo", command => 'make test' },
            { id => 3, kind => 'question' },
            { id => 4, kind => 'plan', needs => [ 1, 2, 3 ] },
        ],
        limits => { concurrent => 4, per_agent => { minimax => 2 } },
        note   => 'first plan',
    );

    like( $chain_id, qr/\A[0-9]{8}T[0-9]{6}Z-[0-9a-f]{6}\z/,
        'write_chain returns a chain id stamped with the moment it was planned' );

    is_deeply(
        [ refs_under( $repo, 'refs/karr-foundation/' ) ],
        [   'refs/karr-foundation/chain/meta',
            'refs/karr-foundation/chain/step/1',
            'refs/karr-foundation/chain/step/2',
            'refs/karr-foundation/chain/step/3',
            'refs/karr-foundation/chain/step/4',
        ],
        'a chain is one ref per step plus the header, all under refs/karr-foundation'
    );
    is_deeply( [ refs_under( $repo, 'refs/karr/' ) ], [],
        'the board namespace is not touched by any of it' );

    my $step = $store->step(1);
    is( $step->{kind},          'ticket',               'kind survives' );
    is( $step->{repo},          "$repo",                'repo survives' );
    is( $step->{ticket},        41,                     'ticket survives' );
    is( $step->{timeout},       1800,                   'timeout survives' );
    is( $step->{precheck},      'ticket_status == todo','precheck survives' );
    is( $step->{on_stall},      'plan',                 'an on_* policy survives' );
    is( $step->{on_rate_limit}, 'requeue',              'and so does the next one' );
    is( $step->{state},         'pending',              'a fresh step is pending' );
    is( $step->{chain},         $chain_id,              'a step knows which chain it belongs to' );
    is_deeply( $store->step(4)->{needs}, [ 1, 2, 3 ], 'needs survives as a list' );

    my $header = $store->header;
    is( $header->{id}, $chain_id, 'the header names the chain' );
    is_deeply( $header->{limits}, { concurrent => 4, per_agent => { minimax => 2 } },
        'limits are carried through untouched -- what they mean is the runner\'s' );
    like( $header->{created}, qr/\A[0-9]{4}-[0-9]{2}-[0-9]{2}T/, 'and when it was planned' );

    # The dividing line of the whole epic: coordination is shared, execution is
    # local. A step that named an agent would plan work that only one machine
    # can do, in state every machine reads.
    my $err = err_of( sub {
        $store->write_chain(
            [ { id => 1, kind => 'ticket', repo => "$repo", ticket => 1,
                agent => 'minimax' } ] );
    } );
    like( $err, qr/names an agent/, 'a step that names an agent is refused' );
    like( $err, qr/local config/,   'and the refusal says where routing belongs' );
    is( $store->header->{id}, $chain_id,
        'a refused chain leaves the one that was there alone' );
    is( scalar( $store->steps ), 4, 'and does not delete its steps' );

    like( err_of( sub { $store->write_chain( [ { id => 1, kind => 'wat' } ] ) } ),
        qr/unknown kind/, 'an unknown kind is refused' );
    like( err_of( sub { $store->write_chain( [ { id => 'a/b', kind => 'plan' } ] ) } ),
        qr/must be alphanumeric/, 'a step id that is not one ref component is refused' );
    like( err_of( sub { $store->write_chain(
            [ { id => 1, kind => 'ticket', repo => "$repo" } ] ) } ),
        qr/needs a ticket id/, 'a ticket step without a ticket is refused' );
};

subtest 'the chain is a DAG: steps with no edge between them run together' => sub {
    my $repo  = init_repo();
    my $store = mk_store($repo);

    $store->write_chain( [
        { id => 1, kind => 'ticket', repo => "$repo", ticket => 10 },
        { id => 2, kind => 'ticket', repo => "$repo", ticket => 11 },
        { id => 3, kind => 'plan', needs => [ 1, 2 ] },
    ] );

    is_deeply( ids_of( $store->ready_steps ), [ 1, 2 ],
        'both steps without a needs edge are ready at once -- that is the concurrency' );

    $store->update_step( 1, sub { $_[0]->{state} = 'done'; $_[0] } );
    is_deeply( ids_of( $store->ready_steps ), [ 2 ],
        'a step that still has an unfinished need is not ready' );

    $store->update_step( 2, sub { $_[0]->{state} = 'done'; $_[0] } );
    is_deeply( ids_of( $store->ready_steps ), [ 3 ],
        'and becomes ready when its last need is done' );

    $store->update_step( 3, sub { $_[0]->{state} = 'done'; $_[0] } );
    is_deeply( ids_of( $store->ready_steps ), [], 'a finished chain has nothing ready' );

    # A cycle is a chain in which nothing ever becomes ready. Refusing it at
    # write time is the difference between a planning error and a fleet that
    # looks healthy and does nothing.
    like(
        err_of( sub {
            $store->write_chain( [
                { id => 1, kind => 'plan', needs => [ 2 ] },
                { id => 2, kind => 'plan', needs => [ 3 ] },
                { id => 3, kind => 'plan', needs => [ 1 ] },
            ] );
        } ),
        qr/cycle through step\(s\) 1, 2, 3/,
        'a cycle is refused and named'
    );
    like(
        err_of( sub {
            $store->write_chain( [ { id => 1, kind => 'plan', needs => [ 9 ] } ] );
        } ),
        qr/needs '9', which is not in this chain/,
        'an edge to a step that does not exist is refused'
    );
    like(
        err_of( sub {
            $store->write_chain( [ { id => 1, kind => 'plan', needs => [ 1 ] } ] );
        } ),
        qr/needs itself/,
        'and so is a self-edge'
    );
    is_deeply( ids_of( $store->steps ), [ 1, 2, 3 ],
        'none of those refusals touched the chain that was there' );

    # The header is the commit point: steps that belong to no current chain are
    # visible but never ready, which is what makes a half-finished replacement
    # harmless.
    $store->git->delete_ref('refs/karr-foundation/chain/meta');
    is( scalar( $store->steps ), 3, 'the steps are still readable without a header' );
    is_deeply( [ $store->ready_steps ], [], 'but nothing runs from a chain with no header' );

    is( $store->clear_chain, 3, 'clear_chain removes what is left' );
    is_deeply( [ refs_under( $repo, 'refs/karr-foundation/' ) ], [],
        'and leaves the namespace empty' );
};

subtest 'a step whose precheck no longer holds goes stale instead of running' => sub {
    my $repo  = init_repo();
    my $store = mk_store($repo);

    is_deeply(
        $store->parse_precheck('ticket_status == todo'),
        { fact => 'ticket_status', op => '==', value => 'todo' },
        'a precheck parses into fact, operator and value'
    );
    is_deeply(
        $store->parse_precheck('ticket_status != "in-progress"'),
        { fact => 'ticket_status', op => '!=', value => 'in-progress' },
        'quotes come off the value'
    );
    is( $store->parse_precheck(''), undef, 'no precheck is not an error' );
    like( err_of( sub { $store->parse_precheck('ticket_status is todo') } ),
        qr/cannot read precheck/, 'an expression that cannot be read is a planning error' );

    ok( $store->precheck_holds( { precheck => 'ticket_status == todo' },
            { ticket_status => 'todo' } ), 'a precheck that matches holds' );
    ok( !$store->precheck_holds( { precheck => 'ticket_status == todo' },
            { ticket_status => 'in-progress' } ), 'one that does not match does not' );
    ok( $store->precheck_holds( {}, {} ), 'a step without a precheck always holds' );

    # Both operators, both answers to "I could not find out": an unanswerable
    # precheck never holds, so the uncertainty always costs a planning round
    # rather than a step that runs against the world it no longer describes.
    ok( !$store->precheck_holds( { precheck => 'ticket_status == todo' }, {} ),
        'a fact nobody supplied makes == not hold' );
    ok( !$store->precheck_holds( { precheck => 'ticket_status != todo' }, {} ),
        'and makes != not hold either' );

    $store->write_chain( [
        { id => 1, kind => 'ticket', repo => "$repo", ticket => 10,
          precheck => 'ticket_status == todo' },
        { id => 2, kind => 'ticket', repo => "$repo", ticket => 11 },
        { id => 3, kind => 'plan', needs => [ 1 ] },
    ] );

    my $stale = $store->mark_stale( 1, 'ticket 10 is in review already' );
    is( $stale->{state}, 'stale', 'a step whose precheck broke is marked stale' );
    is( $stale->{stale_reason}, 'ticket 10 is in review already', 'with the reason' );
    like( $stale->{stale_at}, qr/\A[0-9]{4}-[0-9]{2}-[0-9]{2}T/, 'and the moment' );
    is( $store->step(1)->{state}, 'stale', 'and that is what the ref says' );

    is_deeply( ids_of( $store->ready_steps ), [ 2 ],
        'the stale step is not ready, and neither is the step that needed it' );
    is( $store->mark_stale( 1, 'again' ), undef,
        'marking an already stale step again is a no-op, not a second write' );

    # A chain that carries a precheck nobody can read is refused whole, so the
    # planner hears about it instead of the runner meeting it later.
    like(
        err_of( sub {
            $store->write_chain( [ { id => 1, kind => 'plan',
                precheck => 'ticket_status ~ todo' } ], force => 1 );
        } ),
        qr/cannot read precheck/,
        'an unreadable precheck is caught at write time'
    );
};

subtest 'step updates are compare-and-swap, so one claim wins' => sub {
    plan skip_all => 'fork is not available on this platform' unless $Config{d_fork};

    my $repo  = init_repo();
    my $store = mk_store($repo);
    $store->write_chain(
        [ { id => 1, kind => 'ticket', repo => "$repo", ticket => 10 } ] );

    # 12 processes enter at the same wall-clock instant and all try to take the
    # step from pending to running. Without the CAS both would read pending and
    # both would write running, and two agents would work one ticket.
    my $CONTENDERS = 12;
    my $out   = path( tempdir( CLEANUP => 1 ) );
    my $start = Time::HiRes::time() + 0.4;
    my @pids;
    for my $n ( 1 .. $CONTENDERS ) {
        my $pid = fork;
        BAIL_OUT("fork failed: $!") unless defined $pid;
        if ( !$pid ) {
            my $answer = eval {
                my $mine = mk_store($repo);
                my $left = $start - Time::HiRes::time();
                Time::HiRes::sleep($left) if $left > 0;
                my $got = $mine->update_step( 1, sub {
                    my ( $step ) = @_;
                    return undef unless ( $step->{state} // 'pending' ) eq 'pending';
                    $step->{state} = 'running';
                    $step->{note}  = "claimed by $n";
                    return $step;
                } );
                $got ? 'won' : 'declined';
            };
            $answer = "died: $@" unless defined $answer;
            $answer =~ s/\s+/ /g;
            $out->child($n)->spew_utf8("$answer\n");
            POSIX::_exit(0);
        }
        push @pids, $pid;
    }
    waitpid $_, 0 for @pids;

    my @answers = map {
        my $f = $out->child($_);
        $f->exists ? do { my $l = $f->slurp_utf8; chomp $l; $l } : 'missing'
    } 1 .. $CONTENDERS;

    is( scalar( grep { $_ eq 'won' } @answers ), 1,
        'exactly one process claimed the step' );
    is( scalar( grep { $_ eq 'declined' } @answers ), $CONTENDERS - 1,
        'every other process was told the step was gone, and none of them died' )
        or diag explain \@answers;
    is( $store->step(1)->{state}, 'running', 'the step is running once, not twelve times' );

    is( $store->update_step( 99, sub { $_[0] } ), undef,
        'updating a step that does not exist answers undef' );
    is( $store->update_step( 1, sub { undef } ), undef,
        'and so does a callback that declines' );
    like( $store->step(1)->{note}, qr/\Aclaimed by [0-9]+\z/,
        'one winner left one note behind, and the decliners left none' );

    # A running step is what a replacement has to ask about: wiping one is how
    # a plan and a live agent get out of step with each other.
    like(
        err_of( sub {
            $store->write_chain( [ { id => 7, kind => 'plan' } ] );
        } ),
        qr/running step\(s\) \(1\)/,
        'replacing a chain with a running step is refused'
    );
    ok(
        eval { $store->write_chain( [ { id => 7, kind => 'plan' } ], force => 1 ); 1 },
        'unless the caller says force'
    ) or diag $@;
    is_deeply( ids_of( $store->steps ), [ 7 ], 'the old steps are gone after a replacement' );
};

subtest 'run logs are one ref per run, segmented like the activity log' => sub {
    my $repo  = init_repo();
    my $store = mk_store($repo);

    my $run = $store->new_run_id;
    like( $run, qr/\A[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{6}[0-9a-f]{6}\z/,
        'a run name is <date>-<id>, so the refs sort chronologically' );

    ok( $store->log_run( $run, event => 'start', chain => 'c1' ), 'an entry lands' );
    ok( $store->log_run( $run, event => 'step',  step  => 1, detail => 'done' ),
        'and so does the next' );

    my @entries = $store->run_entries($run);
    is( scalar @entries, 2, 'both entries come back' );
    is( $entries[0]{event}, 'start', 'oldest first' );
    is( $entries[1]{step},  1,       'with their fields' );
    like( $entries[0]{ts}, qr/\A[0-9]{4}-[0-9]{2}-[0-9]{2}T/, 'timestamped for us' );

    is_deeply( [ refs_under( $repo, 'refs/karr-foundation/log/' ) ],
        [ "refs/karr-foundation/log/$run" ],
        'one run is one ref while it fits' );

    # Segmentation, and the reason for it (#171): a ref blob is rewritten whole
    # on every append, so an uncapped run log costs a copy of its own history
    # per entry. A segment is never appended to once it is full.
    my $small = mk_store( $repo, segment_max_bytes => 200 );
    my $long  = $small->new_run_id;
    $small->log_run( $long, event => 'step', step => $_, detail => 'x' x 20 )
        for 1 .. 12;

    my @segments = refs_under( $repo, "refs/karr-foundation/log/$long*" );
    cmp_ok( scalar @segments, '>', 1, 'a run log that outgrows the cap rotates' );
    like( $segments[1], qr/\Q$long\E\+000001\z/, 'into +000001, the activity log spelling' );
    for my $seg ( @segments ) {
        cmp_ok( length( $store->git->read_ref($seg) ), '<=', 200,
            "$seg stays inside the cap" );
    }

    my @long_entries = $small->run_entries($long);
    is( scalar @long_entries, 12, 'every entry is still there across the segments' );
    is_deeply( [ map { $_->{step} } @long_entries ], [ 1 .. 12 ], 'and still in order' );

    is_deeply( [ $store->run_ids ], [ sort ( $run, $long ) ],
        'run_ids folds the segments back into the runs they belong to' );
};

subtest 'retention bounds the namespace by age and by count' => sub {
    my $repo = init_repo();
    # auto_prune off while the fixture is built, or writing the second run would
    # already drop the first one -- which is the behaviour tested at the end.
    my $store = mk_store( $repo, auto_prune => 0, segment_max_bytes => 200 );

    my @old = map { "$_-1200000000ab" } qw( 2020-01-01 2020-01-02 2020-01-03 );
    my $today = POSIX::strftime( '%Y-%m-%d', gmtime() ) . '-120000ffffff';
    $store->log_run( $_, event => 'start' ) for ( @old, $today );
    # The oldest run gets more than one segment, so pruning has to take them all.
    $store->log_run( $old[0], event => 'step', step => $_, detail => 'y' x 20 )
        for 1 .. 12;
    cmp_ok( scalar( refs_under( $repo, "refs/karr-foundation/log/$old[0]*" ) ),
        '>', 1, 'the oldest run has several segments' );

    is_deeply( [ $store->prune_logs( keep_days => 7, keep_runs => 0 ) ], [ @old ],
        'everything older than the age limit is dropped' );
    is_deeply( [ $store->run_ids ], [ $today ], 'and the recent run is kept' );
    is_deeply( [ refs_under( $repo, "refs/karr-foundation/log/$old[0]*" ) ], [],
        'a pruned run takes every one of its segments with it' );

    # Age alone bounds nothing: a fleet busy enough to matter fills two weeks
    # with more refs than anyone wants to fetch. The count is the real ceiling.
    my @fresh = map { POSIX::strftime( '%Y-%m-%d', gmtime() ) . "-12000${_}aaaaaa" } 1 .. 4;
    $store->log_run( $_, event => 'start' ) for @fresh;
    is_deeply( [ $store->prune_logs( keep_days => 0, keep_runs => 2 ) ],
        [ $today, @fresh[ 0, 1 ] ],
        'everything past the newest keep_runs goes, however young it is' );
    is_deeply( [ $store->run_ids ], [ @fresh[ 2, 3 ] ],
        'exactly the newest keep_runs runs are left' );

    # Retention that only runs when somebody types a command bounds nothing, so
    # opening a run log does it.
    my $auto = mk_store( $repo, keep_days => 0, keep_runs => 1 );
    my @left = $auto->run_ids;
    my $next = $auto->new_run_id;
    $auto->log_run( $next, event => 'start' );
    is_deeply(
        [ sort $auto->run_ids ],
        [ sort ( $left[-1], $next ) ],
        'opening a run log drops what retention no longer keeps, before it writes'
    ) or diag explain [ \@left, [ $auto->run_ids ] ];
};

subtest 'set-refs cannot hand-write a chain, get-refs can still read one' => sub {
    my $repo  = init_repo();
    my $store = mk_store($repo);
    $store->write_chain(
        [ { id => 1, kind => 'ticket', repo => "$repo", ticket => 10 } ] );
    my $git = $store->git;

    for my $ref ( 'refs/karr-foundation/chain/step/1',
        'refs/karr-foundation/chain/meta', 'refs/karr-foundation/log/2026-01-01-x' )
    {
        my $err = err_of( sub { $git->validate_helper_ref( $ref, for_write => 1 ) } );
        like( $err, qr/karr-foundation/, "$ref cannot be written by hand" );
        ok( eval { $git->validate_helper_ref($ref); 1 },
            "$ref can still be read" ) or diag $@;
    }

    # The namespace as a whole stays open on purpose: this epic's own design
    # document lives at refs/karr-foundation/spec/fleet-execution.md and was put
    # there with `karr set-refs`.
    ok(
        eval {
            $git->validate_helper_ref( 'refs/karr-foundation/spec/fleet-execution.md',
                for_write => 1 );
            1;
        },
        'the rest of refs/karr-foundation stays writable'
    ) or diag $@;

    my $r = run_karr( $repo, 'set-refs', 'refs/karr-foundation/chain/step/1', 'wrecked' );
    is( $r->{exit}, 1, 'the CLI refuses it as a runtime failure' );
    like( $r->{stderr}, qr/cannot be set by hand/, 'and says so' );
    unlike( $r->{stderr}, qr/line \d+/, 'without a source location' );
    is( $store->step(1)->{kind}, 'ticket', 'the step is untouched' );
};

done_testing;
