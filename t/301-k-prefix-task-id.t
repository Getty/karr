use strict;
use warnings;
use Test::More;
use lib 't/lib';
use TestGit qw( require_git_c );
require_git_c();
use TestKarr qw( run_karr );
use File::Temp qw( tempdir );

use App::karr::Git;
use App::karr::CrossBoard;

# Board ticket 301: the house `kNNN` spelling is accepted as a local task id
# wherever a bare number was expected -- `karr show k30` names the same card as
# `karr show 30`. Before this change `k30` reached refs/karr/tasks/k30/data and
# failed with "Task k30 not found" (exit 1); reproduced by hand on a temp board
# before the fix. The strip is surgical and only at the CLI-argument rim
# (App::karr::Role::BoardAccess/normalize_task_id, parse_ids, Handoff,
# App::karr::Role::DependencyArgs/parse_dependency_ids, and the id side of a
# cross-board BOARD#ID reference). The ref names built from the result stay
# numeric.
#
# A `k`/`K` is stripped only when it sits immediately in front of a run of
# digits with nothing else around it. Every other token -- a bare number, a
# lone `k`, `k1a`, `kanban`, `abc` -- is left verbatim and fails as before,
# which is what keeps the normalizer from being too greedy.

# In-process runner (t/lib/TestKarr.pm): ($cwd, @argv) in, { exit, stdout,
# stderr } out, dispatched through the shared App::karr::Dispatch path.
sub _run_karr { return run_karr(@_) }

sub _init_repo {
  my $repo = tempdir( CLEANUP => 1 );
  system( 'git', 'init', '-q', $repo );
  system( 'git', '-C', $repo, 'config', 'user.email', 'test@example.com' );
  system( 'git', '-C', $repo, 'config', 'user.name', 'Test User' );
  return $repo;
}

sub _init_board {
  my ( $name, @titles ) = @_;
  my $repo = _init_repo();
  is( _run_karr( $repo, 'init', '--name', $name )->{exit}, 0, "board '$name' initialized" );
  is( _run_karr( $repo, 'create', $_ )->{exit}, 0, "created: $_" ) for @titles;
  return $repo;
}

sub _task { App::karr::Git->new( dir => $_[0] )->load_task_ref( $_[1] ) }

subtest 'parse_ids: k30 resolves the same card as 30 (show)' => sub {
  my $repo = _init_board( 'Show Board', 'First card', 'Second card' );

  my $bare = _run_karr( $repo, 'show', '1' );
  my $kform = _run_karr( $repo, 'show', 'k1' );
  is( $kform->{exit}, 0, 'show k1 succeeds' ) or diag( $kform->{stderr} );
  is( $kform->{stdout}, $bare->{stdout}, 'show k1 prints exactly what show 1 does' );

  # Case-insensitive.
  my $upper = _run_karr( $repo, 'show', 'K1' );
  is( $upper->{exit}, 0, 'show K1 succeeds' );
  is( $upper->{stdout}, $bare->{stdout}, 'show K1 matches show 1 too' );

  # A mixed batch: k1, 2 and K2 (deduped by the command) all land.
  my $batch = _run_karr( $repo, 'show', 'k1,2' );
  is( $batch->{exit}, 0, 'mixed batch k1,2 succeeds' ) or diag( $batch->{stderr} );
  like( $batch->{stdout}, qr/First card/,  'card 1 shown via k1' );
  like( $batch->{stdout}, qr/Second card/, 'card 2 shown via bare 2' );
};

subtest 'parse_ids: a mutating batch command applies to the k-form id' => sub {
  my $repo = _init_board( 'Move Board', 'Movable' );

  my $rv = _run_karr( $repo, 'move', 'k1', 'in-progress', '--claim', 'agent-a' );
  is( $rv->{exit}, 0, 'move k1 succeeds' ) or diag( $rv->{stderr} );
  is( _task( $repo, 1 )->status, 'in-progress', 'card 1 was moved' );
};

subtest 'Handoff: the direct pos[0] path accepts k-notation' => sub {
  my $repo = _init_board( 'Handoff Board', 'Handoffable' );
  is( _run_karr( $repo, 'move', '1', 'in-progress', '--claim', 'agent-a' )->{exit},
    0, 'card started' );

  my $rv = _run_karr( $repo, 'handoff', 'K1', '--claim', 'agent-a' );
  is( $rv->{exit}, 0, 'handoff K1 succeeds' ) or diag( $rv->{stderr} );
  like( $rv->{stdout}, qr/Handed off task 1/, 'the numeric id is reported' );
};

subtest 'dependency ids: --depends-on / --add-depends-on accept k-notation' => sub {
  my $repo = _init_board( 'Dep Board', 'Dep one', 'Dep two', 'Needs them' );

  my $create = _run_karr( $repo, 'create', 'Needs k1', '--depends-on', 'k1,2' );
  is( $create->{exit}, 0, 'create --depends-on k1,2 succeeds' ) or diag( $create->{stderr} );
  is_deeply( _task( $repo, 4 )->depends_on, [ 1, 2 ],
    'the k-form and the bare id are both stored as numbers' );

  my $edit = _run_karr( $repo, 'edit', '3', '--add-depends-on', 'K1' );
  is( $edit->{exit}, 0, 'edit --add-depends-on K1 succeeds' ) or diag( $edit->{stderr} );
  is_deeply( _task( $repo, 3 )->depends_on, [1], 'the dependency landed as a number' );
};

subtest 'a token that is not k+digits is left verbatim and still fails' => sub {
  my $repo = _init_board( 'Reject Board', 'Only card' );

  # `kanban` and `k1a` are not the kNNN shape: unchanged, and still not found.
  my $word = _run_karr( $repo, 'show', 'kanban' );
  isnt( $word->{exit}, 0, 'show kanban fails' );
  like( $word->{stderr}, qr/Task kanban not found/, 'the token is echoed verbatim' );

  my $tail = _run_karr( $repo, 'show', 'k1a' );
  isnt( $tail->{exit}, 0, 'show k1a fails' );
  like( $tail->{stderr}, qr/Task k1a not found/, 'a trailing non-digit is not stripped' );

  # A bad dependency id keeps its usage error, and names the value as typed.
  my $dep = _run_karr( $repo, 'edit', '1', '--add-depends-on', 'k1a' );
  is( $dep->{exit}, 2, 'edit --add-depends-on k1a is a usage error' );
  like( $dep->{stderr}, qr/invalid --add-depends-on id "k1a"/,
    'the offending value is named as the caller typed it' );
};

subtest 'CrossBoard: the id side of BOARD#ID accepts k-notation' => sub {
  my $bare  = App::karr::CrossBoard->parse_ref( '--needs', 'other-repo#7' );
  my $kform = App::karr::CrossBoard->parse_ref( '--needs', 'other-repo#k7' );
  is_deeply( $kform, $bare, 'other-repo#k7 parses identically to other-repo#7' );
  is( $kform->{id}, 7, 'the id is the bare number' );

  # A single k only, and still nothing but digits after it.
  eval { App::karr::CrossBoard->parse_ref( '--needs', 'other-repo#kk7' ) };
  like( $@, qr/invalid --needs reference/, 'other-repo#kk7 is still refused' );
  eval { App::karr::CrossBoard->parse_ref( '--needs', 'other-repo#k' ) };
  like( $@, qr/invalid --needs reference/, 'other-repo#k with no digits is refused' );
};

done_testing;
