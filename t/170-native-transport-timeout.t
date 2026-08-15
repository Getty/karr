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
# The remote speaks git://, not ssh:// as the original report did, because
# libgit2 applies these timeouts to its own socket transports only. ssh reads
# go through libssh2 and are still unbounded (measured: still blocked after
# 75 s with both options set) -- that gap is #174, and the git CLI fallback
# remains the bounded route for ssh.
# ---------------------------------------------------------------------------

my @CHILDREN;
END { kill 'KILL', @CHILDREN if @CHILDREN }

# A socket nobody ever accepts on. Kept open for the life of the test.
my $server = IO::Socket::INET->new(
    LocalAddr => '127.0.0.1', LocalPort => 0, Listen => 50, ReuseAddr => 1,
) or plan skip_all => "cannot listen on 127.0.0.1: $!";
my $port = $server->sockport;

sub repo_pointed_at_the_silent_peer {
    my $dir = tempdir( CLEANUP => 1 );
    system( 'git', 'init', '-q', $dir ) == 0 or die "git init: $?";
    system( 'git', '-C', $dir, 'config', 'user.email', 'a@karr.test' );
    system( 'git', '-C', $dir, 'config', 'user.name',  'agent-a' );
    system( 'git', '-C', $dir, 'remote', 'add', 'origin',
        "git://127.0.0.1:$port/silent.git" ) == 0 or die "git remote add: $?";
    return $dir;
}

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

done_testing;
