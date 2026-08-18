use strict;
use warnings;
use Test::More;
use lib 't/lib';
use TestGit qw( require_git_c );
require_git_c();
use File::Temp qw( tempdir );
use IO::Socket::INET;
use POSIX ();
use Time::HiRes ();
use App::karr::Git;
use Git::Libgit2 ();

# ---------------------------------------------------------------------------
# Ticket #170: KARR_TRANSPORT_TIMEOUT bounded the git-CLI transport and
# nothing else, and the CLI only runs after the native libgit2 transport has
# returned. A peer that completes the TCP handshake and then never speaks
# leaves libgit2 in a blocking read, so the timeout was unreachable: measured
# at 300 s with no end in sight, the process asleep at ~1.8% CPU, ended only
# by an external watchdog.
#
# The fix sets libgit2's own network timeouts (GIT_OPT_SET_SERVER_TIMEOUT and
# GIT_OPT_SET_SERVER_CONNECT_TIMEOUT, milliseconds, 0 = no limit) from the
# same environment variable when the repository is opened, so one knob governs
# both transports.
#
# Two things shape this test:
#
#   * The silent peer is a socket that listens and never accepts. The kernel
#     completes the handshake out of the backlog, so the client connects and
#     then waits for an answer that never comes -- no fake server needed.
#
#   * Every transport runs in a forked child. Without the fix the call never
#     returns, and no Perl-level alarm can break into it: a signal that
#     arrives while the interpreter sits in a C call is not delivered to a
#     Perl handler until that call returns. The parent enforces the deadline
#     and kills the child, so a regression costs seconds, not the suite.
#
# The suite below covers git:// first, and ssh:// as its own case, because
# the two used to differ. At the time this test was written libgit2 applied
# GIT_OPT_SET_SERVER_TIMEOUT to its own socket transports (git://, http://,
# https://) only -- ssh:// reads went through libssh2, which retried past
# libgit2's socket timeout regardless of these options (measured: still
# blocked after 75 s with both set). Closing that gap was left to #174, so
# the ssh:// case was untested here and the CLI fallback stayed the only
# bounded route for ssh://.
#
# #174 closed it by pinning Alien::Libgit2 0.002 in cpanfile, which raises
# the pkg-config floor to libgit2 1.9.3 -- the release carrying upstream PR
# #7165, from which libssh2's own reads honour GIT_OPT_SET_SERVER_TIMEOUT the
# same as the socket transports do (verified below: on this machine the
# silent ssh:// peer now returns in ~3 s instead of hanging). That makes
# ssh:// a second instance of the same regression, worth the same test --
# guarded by a version check, since anyone deliberately building against an
# older system libgit2 still needs this file to run: the ssh subtest below
# skips itself under 1.9.3 rather than failing against a libgit2 that was
# never supposed to carry the fix.
# ---------------------------------------------------------------------------

my @CHILDREN;
END { kill 'KILL', @CHILDREN if @CHILDREN }

# A socket nobody ever accepts on. Kept open for the life of the test.
my $server = IO::Socket::INET->new(
    LocalAddr => '127.0.0.1', LocalPort => 0, Listen => 50, ReuseAddr => 1,
) or plan skip_all => "cannot listen on 127.0.0.1: $!";
my $port = $server->sockport;

# $scheme defaults to git:// (the original case); pass scheme => 'ssh' for
# the #174 regression below. Same silent peer either way -- the client
# connects and then waits on a read that never resolves.
sub repo_pointed_at_the_silent_peer {
    my (%args) = @_;
    my $scheme = $args{scheme} // 'git';
    my $dir = tempdir( CLEANUP => 1 );
    system( 'git', 'init', '-q', $dir ) == 0 or die "git init: $?";
    system( 'git', '-C', $dir, 'config', 'user.email', 'a@karr.test' );
    system( 'git', '-C', $dir, 'config', 'user.name',  'agent-a' );
    system( 'git', '-C', $dir, 'remote', 'add', 'origin',
        "$scheme://127.0.0.1:$port/silent.git" ) == 0 or die "git remote add: $?";
    return $dir;
}

# Guard for the ssh:// regression below. Git::Libgit2::version() returns a
# dotted string ("1.9.3") in scalar context but (major, minor, patch) in
# list context -- ask for the list so the floor check is a plain numeric
# comparison, the same shape TestGit::require_git_c uses for the git binary
# itself, rather than a string/version-object parse.
my @LIBGIT2_VERSION = Git::Libgit2::version();
my $HAVE_SSH_TIMEOUT_FIX =
       $LIBGIT2_VERSION[0] > 1
    || ( $LIBGIT2_VERSION[0] == 1 && $LIBGIT2_VERSION[1] > 9 )
    || ( $LIBGIT2_VERSION[0] == 1 && $LIBGIT2_VERSION[1] == 9
         && $LIBGIT2_VERSION[2] >= 3 );

# Run $code in a child and wait at most $deadline seconds for it. Returns
# ( $exit_code, $elapsed ); $exit_code is undef when the child had to be
# killed, which is the signature of the hang this ticket is about.
sub bounded_child {
    my ( $deadline, $code ) = @_;
    my $started = Time::HiRes::time();
    my $pid     = fork;
    die "fork: $!" unless defined $pid;
    unless ($pid) {
        my $rv = eval { $code->() ? 0 : 1 };
        POSIX::_exit( defined $rv ? $rv : 2 );
    }
    push @CHILDREN, $pid;

    my $status;
    while ( ( Time::HiRes::time() - $started ) < $deadline ) {
        if ( waitpid( $pid, POSIX::WNOHANG() ) == $pid ) { $status = $?; last }
        Time::HiRes::sleep(0.05);
    }
    my $elapsed = Time::HiRes::time() - $started;

    unless ( defined $status ) {
        kill 'KILL', $pid;
        waitpid $pid, 0;
    }
    @CHILDREN = grep { $_ != $pid } @CHILDREN;
    return ( defined $status ? $status >> 8 : undef, $elapsed );
}

subtest 'a silent peer ends the native fetch instead of hanging it' => sub {
    my $dir = repo_pointed_at_the_silent_peer();

    my ( $exit, $elapsed ) = bounded_child( 25, sub {
        # The CLI fallback has always had a timeout; disabling it is what
        # pins this test to the native path.
        local $ENV{KARR_NO_CLI_FALLBACK}   = 1;
        local $ENV{KARR_TRANSPORT_TIMEOUT} = 3;
        my $git = App::karr::Git->new( dir => $dir );
        # 1 would mean "fetch succeeded", which cannot happen here.
        return !$git->fetch('origin');
    } );

    ok defined $exit,
        'the fetch returned on its own -- before the fix it never did'
        or diag "still running after ${\ sprintf '%.1f', $elapsed }s; killed";

    SKIP: {
        skip 'the fetch never returned', 2 unless defined $exit;
        is $exit, 0, 'and it reported failure rather than a phantom success';
        cmp_ok $elapsed, '>=', 1.5,
            sprintf 'it waited for the timeout first (%.2fs), so it was the '
                . 'timeout that ended it, not an instant error', $elapsed;
    }
};

subtest 'KARR_TRANSPORT_TIMEOUT=0 still means no limit' => sub {
    my $dir = repo_pointed_at_the_silent_peer();

    # The counter-proof for the subtest above: with the knob turned off the
    # native fetch has to keep waiting. If this one ever ends by itself, the
    # bound measured above came from somewhere other than this setting.
    my ( $exit, $elapsed ) = bounded_child( 8, sub {
        local $ENV{KARR_NO_CLI_FALLBACK}   = 1;
        local $ENV{KARR_TRANSPORT_TIMEOUT} = 0;
        my $git = App::karr::Git->new( dir => $dir );
        return !$git->fetch('origin');
    } );

    ok !defined $exit,
        sprintf 'the fetch was still waiting after %.1fs, so the bound above '
            . 'is the one this board configured', $elapsed;
};

subtest 'a silent ssh:// peer ends the native fetch instead of hanging it' => sub {
    plan skip_all => sprintf(
        'libgit2 %s predates 1.9.3 (libgit2 PR #7165); ssh:// stays '
            . 'unbounded on this build, so this regression cannot run here',
        join( '.', @LIBGIT2_VERSION )
    ) unless $HAVE_SSH_TIMEOUT_FIX;

    my $dir = repo_pointed_at_the_silent_peer( scheme => 'ssh' );

    my ( $exit, $elapsed ) = bounded_child( 25, sub {
        local $ENV{KARR_NO_CLI_FALLBACK}   = 1;
        local $ENV{KARR_TRANSPORT_TIMEOUT} = 3;
        my $git = App::karr::Git->new( dir => $dir );
        # 1 would mean "fetch succeeded", which cannot happen here.
        return !$git->fetch('origin');
    } );

    ok defined $exit,
        'the fetch returned on its own -- below 1.9.3 libssh2 retried past '
            . 'the socket timeout and it never did'
        or diag "still running after ${\ sprintf '%.1f', $elapsed }s; killed";

    SKIP: {
        skip 'the fetch never returned', 2 unless defined $exit;
        is $exit, 0, 'and it reported failure rather than a phantom success';
        cmp_ok $elapsed, '>=', 1.5,
            sprintf 'it waited for the timeout first (%.2fs), so it was the '
                . 'timeout that ended it, not an instant error', $elapsed;
    }
};

done_testing;
