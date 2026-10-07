use strict;
use warnings;
use Test::More;
use lib 't/lib';
use TestGit qw( require_git_c );
require_git_c();
use File::Temp qw( tempdir );
use Path::Tiny;
use Time::HiRes qw( time );
use IO::Select;
use App::karr::Git;

# k325: _run_git drained the child's stdout and stderr with select() on the
# two open3 pipes. perlport: "select (Win32, VMS) Only implemented on
# sockets." There the call fails at once for a pipe, can_read comes back empty
# without waiting, the loop never reads a byte and spins until the deadline --
# so every CLI fallback, the board probe and the ls-files fallback reported a
# timeout for a git that had finished long ago, and with
# KARR_TRANSPORT_TIMEOUT=0 never returned at all.
#
# The output is collected in files now and the child is waited for, which
# needs nothing a platform lacks. What is pinned: the result is the same
# hash as before, in every outcome, and no select is involved in getting it.

plan skip_all => 'needs a POSIX shell for the stand-in git'
    if $^O eq 'MSWin32';

sub repo {
    my $dir = tempdir( CLEANUP => 1 );
    system( 'git', 'init', '-q', $dir );
    return App::karr::Git->new( dir => $dir );
}

# A stand-in `git` first on PATH, as a shell script.
sub with_fake_git {
    my ( $script, $code ) = @_;
    my $bin = tempdir( CLEANUP => 1 );
    my $git = path($bin)->child('git');
    $git->spew("#!/bin/sh\n$script\n");
    $git->chmod(0755);
    local $ENV{PATH} = "$bin:$ENV{PATH}";
    return $code->();
}

# select() the way Win32 answers it for a pipe: at once, and with nothing.
sub without_select {
    my ($code) = @_;
    no warnings 'redefine';
    local *IO::Select::can_read = sub { return };
    return $code->();
}

subtest 'stdout, stderr and the exit status come back' => sub {
    my $git = repo();
    my $run = without_select( sub {
        with_fake_git( 'echo to-stdout; echo to-stderr >&2; exit 3', sub {
            $git->_run_git( { timeout => 5 }, 'anything' );
        } );
    } );
    is $run->{failure}, '', 'the run is not reported as a timeout';
    ok $run->{ok}, 'it ran';
    is $run->{status} >> 8, 3, 'with its exit status';
    is $run->{out}, "to-stdout\n", 'its stdout';
    is $run->{err}, "to-stderr\n", 'and its stderr';
};

subtest 'a real git answers in the time git takes' => sub {
    my $git   = repo();
    my $began = time;
    my $run   = without_select( sub {
        $git->_run_git( { timeout => 30 }, 'rev-parse', '--git-dir' );
    } );
    my $took = time - $began;
    is $run->{failure}, '', 'no timeout';
    is $run->{status}, 0, 'exit 0';
    like $run->{out}, qr/\.git/, 'the answer is there';
    cmp_ok $took, '<', 10, 'long before the deadline' or diag "took ${took}s";
};

subtest 'more output than a pipe buffer holds, on both streams' => sub {
    my $git = repo();
    my $run = with_fake_git(
        'i=0; while [ $i -lt 3000 ]; do '
          . 'echo "out line $i ............................................"; '
          . 'echo "err line $i ............................................" >&2; '
          . 'i=$((i+1)); done',
        sub { $git->_run_git( { timeout => 30 }, 'anything' ) } );
    is $run->{failure}, '', 'neither stream blocks the other';
    is $run->{status}, 0, 'exit 0';
    like $run->{out}, qr/\Aout line 0 /, 'stdout from the start';
    like $run->{err}, qr/\Aerr line 0 /, 'stderr from the start';
    cmp_ok length $run->{out}, '>=', 65_536, 'at least the output limit of it';
    cmp_ok length $run->{out}, '<', 3000 * 58, 'and bounded';
};

subtest 'a git that stalls is killed at the deadline' => sub {
    my $git   = repo();
    my $began = time;
    my $run   = with_fake_git( 'echo "about to stall" >&2; exec sleep 30',
        sub { $git->_run_git( { timeout => 1 }, 'fetch' ) } );
    my $took = time - $began;
    is $run->{failure}, 'timeout', 'reported as a timeout';
    ok !$run->{ok}, 'and not as a run';
    is $run->{timeout}, 1, 'naming the budget';
    like $run->{err}, qr/about to stall/, 'with what it said before stalling';
    cmp_ok $took, '<', 10, 'and the caller is not kept waiting'
        or diag "took ${took}s";
};

subtest 'no git on PATH is a start failure' => sub {
    my $git = repo();
    local $ENV{PATH} = '';
    my $run = $git->_run_git( { timeout => 5 }, 'rev-parse' );
    is $run->{failure}, 'start', 'reported as a failure to start';
    ok length $run->{err}, 'with a reason';
};

subtest 'no limit means waiting, not spinning forever' => sub {
    my $git = repo();
    my $run = without_select( sub {
        with_fake_git( 'echo done', sub {
            local $SIG{ALRM} = sub { die "still running after 20s\n" };
            alarm 20;
            my $r = $git->_run_git( { timeout => 0 }, 'anything' );
            alarm 0;
            $r;
        } );
    } );
    is $run->{failure}, '', 'a timeout of 0 returns when git does';
    is $run->{out}, "done\n", 'with its output';
};

done_testing;
