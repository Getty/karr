use strict;
use warnings;
use Test::More;
use lib 't/lib';
use TestGit qw( require_git_c );
require_git_c();
use TestKarr qw( run_karr );
use File::Temp qw( tempdir );
use Path::Tiny qw( path );
use YAML::XS qw( Dump );

use App::karr::Git;
use App::karr::BoardStore;
use App::karr::Task;

# Ticket #225: `karr --help` advertises --dir as THE root option ("USAGE: karr
# [--dir PATH] <command>"), and every board command honours it in that
# position. `karr dashboard` did not: --dir is declared on
# App::karr::Role::BoardDiscovery, dashboard composes neither that role nor
# BoardAccess, and MooX::Cmd leaves the parsed value sitting on the root
# instance in the command chain. So the option was accepted, discarded without
# a word, and the scan ran on the current directory -- printing a list of
# repositories with counts behind them, which always looks plausible. Measured
# before the fix, from a directory holding a board called "alpha", with --dir
# pointing at a wholly separate tree holding "beta":
#
#   karr --dir THERE dashboard --compact
#   -> alpha  backlog:1,...        (exit 0)
#
# The other placement was already loud and right: `karr dashboard --dir THERE`
# is rejected by MooX::Options as an unknown option, exit 2.
#
# Resolution: refuse the root form too, and say where the scan root goes. The
# two paths are not the same path -- --dir seeds the walk UPWARD to one
# repository's root (BoardDiscovery::_build_git_root), dashboard's positional
# PATH is the root of a walk DOWNWARD through a tree of repositories
# (Dashboard::_find_repos, bounded by --depth) -- so adopting one as the other
# would have made the same argument mean a different directory per command.
#
# Everything here runs against throwaway repositories under File::Temp; the
# developer's own board is never touched.

# In-process runner (t/lib/TestKarr.pm): same ($cwd, @argv) signature and
# { exit, stdout, stderr } return as the open3 helper this file used to carry,
# dispatched through the shared App::karr::Dispatch path. KARR_TEST_SUBPROC=1
# restores the old open3 path.
sub _run_karr { return run_karr(@_) }

# A Git repository with an initialized karr board and one backlog task per id.
sub _board_repo {
    my ( $dir, $name, @ids ) = @_;
    $dir->mkpath;
    system( 'git', 'init', '-q', "$dir" ) == 0 or BAIL_OUT('git init failed');
    system( 'git', '-C', "$dir", 'config', 'user.email', 'test@example.com' ) == 0
        or BAIL_OUT('git config failed');
    system( 'git', '-C', "$dir", 'config', 'user.name', 'Test User' ) == 0
        or BAIL_OUT('git config failed');

    my $git = App::karr::Git->new( dir => "$dir" );
    $git->write_ref( 'refs/karr/config', Dump( { version => 1, board => { name => $name } } ) );
    my $store = App::karr::BoardStore->new( git => $git );
    $store->save_task(
        App::karr::Task->new(
            id     => $_,
            title  => "Task $_ on $name",
            status => 'backlog',
            class  => 'standard',
        )
    ) for @ids;
    return $store;
}

# Two trees that cannot be mistaken for one another: the command runs from
# HERE, and --dir points at THERE. "alpha" appearing in the output means the
# current directory was described; "beta" means the tree named by --dir was.
my $tmp   = path( tempdir( CLEANUP => 1 ) );
my $here  = $tmp->child('here');
my $there = $tmp->child('there');
_board_repo( $here->child('alpha'), 'Alpha', 1 );
_board_repo( $there->child('beta'), 'Beta', 1, 2 );

subtest 'the root form is refused, and says where the scan root goes' => sub {
    my $r = _run_karr( "$here", '--dir', "$there", 'dashboard', '--compact' );

    is $r->{exit}, 2, 'exit 2 -- a usage error, not a successful answer (ADR 0002)';
    like $r->{stderr}, qr/--dir/, 'the message names the option that was refused';
    like $r->{stderr}, qr/karr dashboard PATH/,
        'and points at the positional scan root instead';

    # The heart of #225: the old behaviour was not a wrong exit code, it was a
    # plausible-looking answer to a question nobody asked.
    unlike $r->{stdout}, qr/alpha/, 'the current directory is NOT described instead';
    is $r->{stdout}, '', 'nothing at all on stdout';
};

subtest 'a positional PATH alongside --dir does not rescue it' => sub {
    # The precedence question the ticket raised, answered by not having one:
    # --dir is never adopted here, so there is nothing for a positional to win
    # against. Documented in Cmd/Dashboard.pm's SEARCH section.
    my $r = _run_karr( "$here", '--dir', "$there", 'dashboard', "$there", '--compact' );
    is $r->{exit}, 2, 'still a usage error';
    like $r->{stderr}, qr/karr dashboard PATH/, 'same message';
    is $r->{stdout}, '', 'and no board list';
};

subtest 'the documented way to scan another tree still works' => sub {
    my $r = _run_karr( "$here", 'dashboard', "$there", '--compact' );
    is $r->{exit}, 0, 'positional PATH succeeds';
    like $r->{stdout}, qr/^beta\t/m, 'and describes the tree it was given';
    unlike $r->{stdout}, qr/alpha/, 'not the current directory';
};

subtest 'without --dir the current directory is described as before' => sub {
    my $r = _run_karr( "$here", 'dashboard', '--compact' );
    is $r->{exit}, 0, 'no false rejection when no --dir was given anywhere';
    like $r->{stdout}, qr/^alpha\t/m, 'the current directory is the default scan root';
};

subtest 'the subcommand placement stays the loud unknown option it was' => sub {
    my $r = _run_karr( "$here", 'dashboard', '--dir', "$there", '--compact' );
    is $r->{exit}, 2, 'exit 2';
    like $r->{stderr}, qr/Unknown option: dir/, 'rejected by MooX::Options itself';
    is $r->{stdout}, '', 'no board list';
};

subtest '--dir keeps its meaning for the board commands' => sub {
    # The refusal above is dashboard's alone: nothing here narrows the root
    # option for the commands that do discover a board from it.
    my $r = _run_karr( "$here", '--dir', "$there/beta", 'list', '--compact' );
    is $r->{exit}, 0, 'karr --dir PATH list still succeeds';
    like $r->{stdout}, qr/Task 1 on Beta/, 'and reads the board under that path';
};

done_testing;
