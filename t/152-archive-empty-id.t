use strict;
use warnings;
use Test::More;
use lib 't/lib';
use TestGit qw( require_git_c );
require_git_c();
use TestKarr qw( run_karr run_karr_stdin );
use File::Temp qw( tempdir );

use App::karr::Git;

# Regression for karr board ticket #152:
#   `karr archive ,` did nothing, said nothing, exited 0. The same `or die
#   "Usage: ..."` guard in Cmd/Archive.pm that lets "," slip past (because
#   "," is truthy) was fixed in Cmd::Move, Cmd::Edit and Cmd::Delete by
#   `die "Usage: ..." unless @ids;` -- Archive.pm was left out, so an id
#   list with no ids reported success for an archive that never happened.
#   The other three exit 2 with a "Usage:" line; this pins Archive to the
#   same shape.

# In-process runner (t/lib/TestKarr.pm): same ($cwd, $stdin, @argv) signature
# and { exit, stdout, stderr } return as the open3 helper this file used to
# carry, dispatched through the shared App::karr::Dispatch path.
# KARR_TEST_SUBPROC=1 restores the old open3 path.
sub _run_karr {
    my ( $cwd, $stdin, @argv ) = @_;
    return defined $stdin
        ? run_karr_stdin( $cwd, $stdin, @argv )
        : run_karr( $cwd, @argv );
}

sub _setup_repo {
    my $repo = tempdir( CLEANUP => 1 );
    system( 'git', 'init', '-q', $repo ) == 0                                     or die 'git init';
    system( 'git', '-C', $repo, 'config', 'user.email', 'test@example.com' ) == 0 or die 'git config';
    system( 'git', '-C', $repo, 'config', 'user.name', 'Test User' ) == 0         or die 'git config';

    my $init = _run_karr( $repo, undef, 'init', '--name', 'Archive Empty Board' );
    is( $init->{exit}, 0, 'karr init succeeds' ) or diag $init->{stderr};

    my $create = _run_karr( $repo, undef, 'create', '--title', 'Task 1', '--status', 'todo' );
    is( $create->{exit}, 0, 'seed task 1 created' ) or diag $create->{stderr};

    return $repo;
}

sub _task_status {
    my ( $repo, $id ) = @_;
    return App::karr::Git->new( dir => $repo )->load_task_ref( $id // 1 )->status;
}

subtest 'archive , is a usage error, not a silent no-op (#152)' => sub {
    my $repo = _setup_repo();

    my $rv = _run_karr( $repo, undef, 'archive', ',' );
    is( $rv->{exit}, 2, 'karr archive , exits 2' )
        or diag $rv->{stdout} . $rv->{stderr};
    like( $rv->{stderr}, qr/^Usage:/m, '...with a Usage: line on stderr' );

    # The seeded task is still there, still todo.
    is( _task_status($repo), 'todo', 'and the seeded task was not archived' );
};

subtest 'archive ,, --json is a usage error, not an empty success (#152)' => sub {
    my $repo = _setup_repo();

    my $rv = _run_karr( $repo, undef, 'archive', ',,', '--json' );
    is( $rv->{exit}, 2, 'karr archive ,, --json exits 2' )
        or diag $rv->{stdout} . $rv->{stderr};
    like( $rv->{stderr}, qr/^Usage:/m, '...with a Usage: line on stderr' );

    is( _task_status($repo), 'todo', 'and the seeded task was not archived' );
};

subtest 'archive with a real id still works (#152 regression guard)' => sub {
    my $repo = _setup_repo();

    my $rv = _run_karr( $repo, undef, 'archive', 1 );
    is( $rv->{exit}, 0, 'karr archive 1 succeeds' ) or diag $rv->{stderr};
    is( _task_status($repo), 'archived', 'and the task is archived' );
};

done_testing;
