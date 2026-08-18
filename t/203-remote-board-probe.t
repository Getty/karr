use strict;
use warnings;
use Test::More;
use lib 't/lib';
use TestGit qw( require_git_c );
require_git_c();
use File::Temp qw( tempdir );
use IO::Socket::INET;
use Time::HiRes ();
use App::karr::Git;

# ---------------------------------------------------------------------------
# Ticket #203: App::karr::Git/remote_has_board -- the probe that runs unasked
# in front of every read command in a board-less repository (#173) -- used to
# take the git CLI and only the git CLI. The reason was #174: libssh2 retried
# past libgit2's socket timeout, so a native ssh:// probe had no deadline at
# all, and an unasked round trip without a deadline is worse than no probe.
# The 1.9.3 floor cpanfile pins closed that, so the probe joins the house
# policy of the rest of the class: native first, CLI as the fallback.
#
# Three properties have to survive the swap, and each gets a subtest:
#
#   the three answers stay apart   1 / 0 / undef, with last_error on undef
#   the CLI is still the fallback  it is what reaches a remote libgit2 cannot
#                                  resolve, and KARR_NO_CLI_FALLBACK now means
#                                  "native only" rather than "do not ask"
#   the budget is spent once       a silent remote must not burn the cap
#                                  natively and then the cap again on the CLI
# ---------------------------------------------------------------------------

sub _sh {
    my (@cmd) = @_;
    system(@cmd) == 0 or BAIL_OUT("failed: @cmd");
    return;
}

# A work tree with a board pushed to a bare origin, plus a boardless bare repo
# to point other remotes at.
sub _fixture {
    my $work = tempdir( CLEANUP => 1 );
    _sh( 'git', 'init', '-q', '--bare', "$work/board.git" );
    _sh( 'git', 'init', '-q', '--bare', "$work/empty.git" );
    _sh( 'git', 'init', '-q', "$work/src" );
    _sh( 'git', '-C', "$work/src", 'config', 'user.email', 'test@example.com' );
    _sh( 'git', '-C', "$work/src", 'config', 'user.name',  'Test User' );

    # One board ref is enough: the probe asks what the remote advertises under
    # refs/karr/, not what a board needs to be complete.
    my $oid = `printf board-id | git -C '$work/src' hash-object -w --stdin`;
    $oid =~ s/\s+//g;
    _sh( 'git', '-C', "$work/src", 'update-ref', 'refs/karr/meta/board-id', $oid );
    _sh( 'git', '-C', "$work/src", 'remote', 'add', 'board', "$work/board.git" );
    _sh( 'git', '-C', "$work/src", 'push', '-q', 'board', 'refs/karr/*:refs/karr/*' );
    _sh( 'git', '-C', "$work/src", 'remote', 'add', 'empty', "$work/empty.git" );

    return ( $work, App::karr::Git->new( dir => "$work/src" ) );
}

# A socket that listens and never accepts: the kernel completes the handshake
# from the backlog, so a client connects and then waits for an answer that
# never comes. The remote that is silent rather than absent is the one the
# probe's budget exists for.
sub _silent_port {
    my $server = IO::Socket::INET->new(
        LocalAddr => '127.0.0.1', LocalPort => 0, Listen => 50, ReuseAddr => 1,
    ) or return undef;
    # Held open for the life of the test: closing it would make the connection
    # fail fast, which is the opposite of what is being measured.
    return ( $server->sockport, $server );
}

subtest 'the native transport answers the probe on its own' => sub {
    my ( $work, $git ) = _fixture();

    # KARR_NO_CLI_FALLBACK leaves the native attempt alone, so every answer
    # under it is one libgit2 produced. Before #203 all three were undef.
    local $ENV{KARR_NO_CLI_FALLBACK} = 1;

    is( $git->remote_has_board('board'), 1,
        'a remote advertising refs/karr/* answers 1, natively' );
    is( $git->remote_has_board('empty'), 0,
        'a remote that answered and has no board is 0, not undef' );
    is( $git->remote_has_board('nosuch'), 0,
        'a remote that is not configured is 0 as well -- nothing to ask' );

    # The refs a board does not own must not be mistaken for one: the native
    # listing is the remote's own ref names, HEAD and refs/heads/* included.
    _sh( 'git', '-C', "$work/src", 'commit', '-q', '--allow-empty', '-m', 'x' );
    _sh( 'git', '-C', "$work/src", 'push', '-q', 'empty', 'HEAD:refs/heads/main' );
    is( $git->remote_has_board('empty'), 0,
        'a remote with branches but no refs/karr/* is still 0' );
};

subtest 'the CLI stays the fallback for a remote libgit2 cannot resolve' => sub {
    my ( $work, $git ) = _fixture();

    # The real case is a ~/.ssh/config Host alias, an IdentityFile or a
    # ProxyCommand -- none of which libgit2 reads, and none of which a test can
    # set up without an sshd. A relative remote URL is the same shape and needs
    # nothing: `git -C <root>` resolves it against the work tree root, libgit2
    # does not resolve it at all.
    _sh( 'git', '-C', "$work/src", 'remote', 'add', 'rel', '../board.git' );

    is( $git->remote_has_board('rel'), 1,
        'the CLI fallback answers where the native transport cannot' );

    {
        local $ENV{KARR_NO_CLI_FALLBACK} = 1;
        my $answer = $git->remote_has_board('rel');
        is( $answer, undef,
            'and with the fallback off the question goes unanswered' );
        like( $git->last_error, qr/\S/,
            'with last_error carrying libgit2 reason for it' );
    }

    # Both routes failing is still undef, and the reason is the last one tried:
    # git's wording, which is what proves the CLI ran after the native attempt.
    _sh( 'git', '-C', "$work/src", 'remote', 'add', 'nowhere', "$work/nowhere.git" );
    is( $git->remote_has_board('nowhere'), undef,
        'a remote that is not a repository cannot answer' );
    like( $git->last_error, qr/does not appear to be a git repository/,
        'and the reason is the git CLI, so the fallback ran after the native attempt' );
};

subtest 'the probe budget is split between the two attempts, not spent twice' => sub {
    my ( $port, $server ) = _silent_port();
    plan skip_all => "cannot listen on 127.0.0.1: $!" unless $port;

    my ( $work, $git ) = _fixture();
    _sh( 'git', '-C', "$work/src", 'remote', 'add', 'silent',
        "git://127.0.0.1:$port/silent.git" );

    local $ENV{KARR_TRANSPORT_TIMEOUT} = 3;   # under the probe's 10s cap

    my $started = Time::HiRes::time();
    my $answer  = $git->remote_has_board('silent');
    my $elapsed = Time::HiRes::time() - $started;

    is( $answer, undef, 'a remote that never speaks cannot answer' );
    like( $git->last_error, qr/no answer within 3s/,
        'and the deadline is reported as the whole probe, not as one attempt' );
    cmp_ok( $elapsed, '>=', 1.5, sprintf
        'it waited for a deadline (%.2fs), so this is not an instant failure',
        $elapsed );
    cmp_ok( $elapsed, '<', 5.4, sprintf
        'and it waited for that deadline once (%.2fs), not once per transport',
        $elapsed );
};

subtest 'the probe puts the transport budget back when it is done' => sub {
    my ( $port, $server ) = _silent_port();
    plan skip_all => "cannot listen on 127.0.0.1: $!" unless $port;

    my ( $work, $git ) = _fixture();
    _sh( 'git', '-C', "$work/src", 'remote', 'add', 'silent',
        "git://127.0.0.1:$port/silent.git" );

    # The probe lowers libgit2's server timeout to its own share -- a
    # process-global, not per-object state. A transport that runs afterwards
    # has to get the budget it was configured with, not the probe's half of it.
    local $ENV{KARR_TRANSPORT_TIMEOUT} = 2;
    $git->remote_has_board('silent');

    local $ENV{KARR_NO_CLI_FALLBACK} = 1;   # time the native leg alone
    my $started = Time::HiRes::time();
    is( $git->fetch('silent'), 0, 'the fetch fails against a silent remote' );
    my $elapsed = Time::HiRes::time() - $started;

    cmp_ok( $elapsed, '>=', 1.6, sprintf
        'and it had the whole 2s to fail in (%.2fs), not the probe share of 1s',
        $elapsed );
};

done_testing;
