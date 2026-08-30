use strict;
use warnings;
use Test::More;
use lib 't/lib';
use TestGit qw( require_git_c );
require_git_c();
use TestKarr qw( run_karr );
use File::Temp qw( tempdir );
use YAML::XS qw( Load );

use App::karr::Git;

sub _git_ok {
    my (@cmd) = @_;
    my $rc = system(@cmd);
    is($rc, 0, "@cmd");
}

# In-process runner (t/lib/TestKarr.pm): same ($cwd, @argv) signature and
# { exit, stdout, stderr } return as the open3 helper this file used to carry,
# dispatched through the shared App::karr::Dispatch path. KARR_TEST_SUBPROC=1
# restores the old open3 path.
sub _run_karr { return run_karr(@_) }

subtest 'init fails outside git repositories' => sub {
    my $dir = tempdir( CLEANUP => 1 );
    my $rv = _run_karr( $dir, 'init', '--name', 'No Git' );
    isnt( $rv->{exit}, 0, 'init fails outside git repos' );
    like( $rv->{stderr}, qr/git repository/i, 'stderr explains the git requirement' );
};

subtest 'init writes refs instead of creating karr/' => sub {
    my $repo = tempdir( CLEANUP => 1 );
    _git_ok( 'git', 'init', '-q', $repo );
    _git_ok( 'git', '-C', $repo, 'config', 'user.email', 'test@example.com' );
    _git_ok( 'git', '-C', $repo, 'config', 'user.name', 'Test User' );

    my $rv = _run_karr( $repo, 'init', '--name', 'Ref Init' );
    is( $rv->{exit}, 0, 'init exits successfully in git repos' );
    like( $rv->{stdout}, qr/Initialized karr board/i, 'stdout reports successful init' );

    ok( !-d "$repo/karr", 'no persistent karr directory is created' );

    my $git = App::karr::Git->new( dir => $repo );
    my $config = Load( $git->read_ref('refs/karr/config') );
    is( $config->{board}{name}, 'Ref Init', 'board name is stored in refs' );
    is( $git->read_next_id_ref, 1, 'next-id metadata ref is initialized' );
};

done_testing;
