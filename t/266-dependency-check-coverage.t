use strict;
use warnings;
use Test::More;

# Ticket k266: Devel::Cover reported low coverage for
# App::karr::Role::DependencyCheck. A targeted run of the tests that already
# exist (t/125-dependency-warnings.t, t/192-cross-board-dependencies.t and
# friends) turned out to already exercise every statement and every branch in
# the file -- what was still open was one *condition* inside a compound
# boolean (see the last unit subtest below) and a handful of edge cases the
# ticket named explicitly: cycles, a satisfied-vs-unsatisfied mix, and a
# command (handoff) that calls into this role but had no test of its own.
#
# The first half below composes App::karr::Role::DependencyCheck onto a bare
# stub -- the same style t/135-dependency-check-requires.t and
# t/140-dependency-role-split.t already use to test this role in isolation --
# rather than driving it through `karr move`/`karr pick`. That is deliberate
# here: a self-reference, a two-card cycle, and a hand-planted stash value are
# all about the algorithm inside check_dependencies/dependency_report, not
# about any one command's wiring, and constructing them through the CLI would
# either be impossible (nothing lets an operator create a self-referencing
# depends_on) or would just be re-proving t/125's ground one more time. No
# git repository is touched by that half, exactly as none is touched by 135 or
# 140 -- there is no board state involved, only the role's own bookkeeping.
#
# The second half is the opposite: `karr handoff` composes this role through
# App::karr::Role::TaskMutation (t/140 pins that) but, unlike move/edit/pick,
# had no test asserting it actually warns. That is a real command-level gap
# and belongs behind the CLI, in its own isolated temp git repo, the way
# t/125's subtests are.

package DC::TestConsumer;
use Moo;

# Minimal stand-ins for the four collaborators DependencyCheck requires
# (t/135 pins the list). `store` returns $self so is_terminal_status lives
# right here rather than needing a second stub object. Declared before `with`
# below, the same order t/135's StubConsumer uses -- Role::Tiny checks
# `requires` at composition time, so a method meant to satisfy it has to exist
# on the class before the role is applied.
has _terminal => ( is => 'rw', default => sub { {} } );
has _tasks    => ( is => 'rw', default => sub { {} } );
has json      => ( is => 'rw', default => sub { 1 } );
has quiet     => ( is => 'rw', default => sub { 0 } );

sub store              { $_[0] }
sub is_terminal_status { my ( $self, $status ) = @_; return $self->_terminal->{$status} ? 1 : 0 }
sub find_task          { my ( $self, $id )     = @_; return $self->_tasks->{$id} }

with 'App::karr::Role::DependencyCheck';

package main;

use App::karr::Role::DependencyCheck;
use App::karr::Task;

sub _consumer {
    my $dc = DC::TestConsumer->new;
    $dc->_terminal( { done => 1, archived => 1 } );
    return $dc;
}

subtest 'a terminal move clears a previously stashed warning, not just skips reporting it' => sub {
    my $dc = _consumer();
    my $a  = App::karr::Task->new( id => 1, title => 'A', status => 'todo' );
    my $b  = App::karr::Task->new( id => 2, title => 'B', status => 'todo', depends_on => [1] );
    $dc->_tasks( { 1 => $a, 2 => $b } );

    my @first = $dc->check_dependencies( $b, 'in-progress' );
    is( scalar @first, 1, 'the unfinished dependency is stashed' );
    my %report1 = $dc->dependency_report(2);
    ok( exists $report1{dependency_warnings}, 'and dependency_report can see it' );

    # check_dependencies deletes the stashed slot for this id BEFORE it looks
    # at whether $new_status is terminal (App::karr::Role::DependencyCheck.pm,
    # the `delete ...; return () if ... is_terminal_status` order). A finish
    # is not a report -- it does not just decline to add a new warning, it
    # wipes out whatever the last check for this id left behind.
    my @second = $dc->check_dependencies( $b, 'done' );
    is_deeply( \@second, [], 'finishing the card returns no warnings' );
    my %report2 = $dc->dependency_report(2);
    ok( !exists $report2{dependency_warnings},
        'and the stale warning from the earlier, unfinished check is gone too' );
};

subtest 'a self-referencing dependency warns about itself without looping' => sub {
    my $dc = _consumer();
    my $c  = App::karr::Task->new( id => 3, title => 'C', status => 'todo', depends_on => [3] );
    $dc->_tasks( { 3 => $c } );

    my @w = $dc->check_dependencies( $c, 'in-progress' );
    is( scalar @w, 1, 'one warning -- reaching this line at all is the point' );
    like( $w[0], qr/task 3 depends on task 3, which is still todo/,
        'it is named the same way any other unfinished dependency is' );
};

subtest 'a dependency cycle warns on both sides without looping' => sub {
    my $dc = _consumer();
    my $x  = App::karr::Task->new( id => 10, title => 'X', status => 'todo', depends_on => [11] );
    my $y  = App::karr::Task->new( id => 11, title => 'Y', status => 'todo', depends_on => [10] );
    $dc->_tasks( { 10 => $x, 11 => $y } );

    # check_dependencies looks each dependency's status up directly -- it does
    # not walk the graph -- so a cycle is not a special case in the code. The
    # test still earns its place: it is exactly the kind of input a hand-typed
    # --depends-on invites, and this pins that it stays two independent,
    # unremarkable warnings rather than a hang or a crash.
    my @wx = $dc->check_dependencies( $x, 'in-progress' );
    is( scalar @wx, 1, 'X names Y' );
    like( $wx[0], qr/task 10 depends on task 11, which is still todo/, '...unfinished' );

    my @wy = $dc->check_dependencies( $y, 'in-progress' );
    is( scalar @wy, 1, 'and Y names X right back' );
    like( $wy[0], qr/task 11 depends on task 10, which is still todo/, '...also unfinished' );
};

subtest 'a local dependency and a cross-board link on the same card both stash, local first' => sub {
    my $dc = _consumer();
    my $a  = App::karr::Task->new( id => 1, title => 'A', status => 'todo' );
    my $d  = App::karr::Task->new(
        id => 20, title => 'D', status => 'todo',
        depends_on => [1], tags => ['needs:other#7'],
    );
    $dc->_tasks( { 1 => $a, 20 => $d } );

    my @w = $dc->check_dependencies( $d, 'in-progress' );
    is( scalar @w, 2, 'both warnings are recorded from the one call' );
    like( $w[0], qr/task 20 depends on task 1, which is still todo/,
        'the board-local one, from the depends_on loop, comes first' );
    like( $w[1], qr/task 20 waits on other#7 on another board/,
        'the cross-board one, from the needs loop, follows it' );
};

subtest 'dependency_report treats a defined-but-empty stash the same as no stash at all' => sub {
    # check_dependencies never leaves this state behind on its own: it only
    # ever stores a non-empty arrayref (`... = \@warnings if @warnings`) or
    # deletes the slot outright, so dependency_report's `$warnings &&
    # @$warnings` guard has a branch -- $warnings true, @$warnings false --
    # that no call through check_dependencies can reach. Devel::Cover's
    # condition report is exactly what flagged it (App::karr::Role::
    # DependencyCheck.pm:174). The guard is still there on purpose, and this
    # plants the state by hand to pin what it is defending: an id whose stash
    # is a reference to an empty list must report nothing, not an empty
    # warning entry.
    my $dc = _consumer();
    $dc->_dependency_warnings->{99} = [];

    my %report = $dc->dependency_report(99);
    is_deeply( \%report, {}, 'nothing is reported, and the key is absent' );
};

subtest 'a card with neither depends_on nor a needs tag never touches the stash' => sub {
    my $dc = _consumer();
    my $e  = App::karr::Task->new( id => 30, title => 'E', status => 'todo' );
    $dc->_tasks( { 30 => $e } );

    my @w = $dc->check_dependencies( $e, 'in-progress' );
    is_deeply( \@w, [], 'nothing to warn about' );
    my %report = $dc->dependency_report(30);
    is_deeply( \%report, {}, 'and nothing was ever stashed for it to find' );
};

# ---------------------------------------------------------------------------
# The command-level gap: `karr handoff` calls into this role exactly as
# move/edit/pick do (App::karr::Cmd::Handoff -> apply_status_change ->
# check_dependencies, then its own dependency_report call), but unlike them
# had no test asserting it. Through the CLI now, in its own throwaway repo.
# ---------------------------------------------------------------------------

use lib 't/lib';
use TestGit qw( require_git_c );
require_git_c();
use TestKarr qw( run_karr );
use File::Temp qw( tempdir );
use JSON::MaybeXS qw( decode_json );

use App::karr::Git;
use App::karr::BoardStore;

sub _board {
    my (@specs) = @_;
    my $repo = tempdir( CLEANUP => 1 );
    system( 'git', 'init', '-q', $repo ) == 0 or die 'git init';
    system( 'git', '-C', $repo, 'config', 'user.email', 'test@example.com' ) == 0
        or die 'git config';
    system( 'git', '-C', $repo, 'config', 'user.name', 'Test User' ) == 0
        or die 'git config';

    my $init = run_karr( $repo, 'init', '--name', 'Handoff Dep Board' );
    die "karr init failed: $init->{stderr}" if $init->{exit};

    my $git   = App::karr::Git->new( dir => $repo );
    my $store = App::karr::BoardStore->new( git => $git );
    for my $spec (@specs) {
        $store->save_task(
            App::karr::Task->new(
                id     => $spec->{id},
                title  => $spec->{title} // "Task $spec->{id}",
                status => $spec->{status},
                ( $spec->{depends_on} ? ( depends_on => $spec->{depends_on} ) : () ),
            )
        );
    }
    $git->write_ref( 'refs/karr/meta/next-id', "50\n" );
    return $repo;
}

subtest 'karr handoff warns about an unfinished dependency, same as move/edit/pick' => sub {
    my $repo = _board(
        { id => 1, status => 'todo' },
        { id => 2, status => 'todo', depends_on => [1] },
    );

    my $r = run_karr( $repo, 'handoff', '2', '--claim', 'agent-h' );
    is( $r->{exit}, 0, 'handoff succeeds' ) or diag $r->{stderr};
    like( $r->{stderr}, qr/task 2 depends on task 1, which is still todo/,
        'apply_status_change into the review column warns exactly as a move would (k123)' );
    like( $r->{stdout}, qr/Handed off task 2 -> review/, 'STDOUT reports the handoff as usual' );
    unlike( $r->{stdout}, qr/depends on/, 'and carries no warning of its own' );
};

subtest 'and carries it in --json, the same key move/edit/pick use' => sub {
    my $repo = _board(
        { id => 1, status => 'todo' },
        { id => 2, status => 'todo', depends_on => [1] },
    );

    my $r = run_karr( $repo, 'handoff', '2', '--claim', 'agent-h', '--json' );
    is( $r->{exit}, 0, 'handoff succeeds' ) or diag $r->{stderr};
    unlike( $r->{stderr}, qr/depends on/, 'nothing on STDERR under --json' );

    my $data = decode_json( $r->{stdout} );
    is( ref $data->{dependency_warnings}, 'ARRAY', 'the warning rides in the result object' );
    is( scalar @{ $data->{dependency_warnings} }, 1, 'one unsatisfied dependency' );
    like( $data->{dependency_warnings}[0], qr/depends on task 1, which is still todo/,
        'the same sentence STDERR would have carried' );
};

subtest 'a satisfied dependency at handoff time says nothing' => sub {
    my $repo = _board(
        { id => 1, status => 'done' },
        { id => 2, status => 'todo', depends_on => [1] },
    );

    my $r = run_karr( $repo, 'handoff', '2', '--claim', 'agent-h' );
    is( $r->{exit}, 0, 'handoff succeeds' ) or diag $r->{stderr};
    unlike( $r->{stderr}, qr/depends on/,
        'a dependency in a terminal status is satisfied, so handoff says nothing either' );
};

done_testing;
