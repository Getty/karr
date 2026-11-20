#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use lib 't/lib';
use TestGit qw( require_git_c );
require_git_c();
use File::Temp qw( tempdir );
use App::karr::Git;
use App::karr::Task;
use Git::Native::Error;
use Git::Libgit2 qw( GIT_EAUTH );

# Ticket k333, part A: a failed push is classified from what the transport
# said, because the verdict decides whether a second attempt is worth making.
# "Denied" (no credentials, a key the remote does not accept, no write
# permission) is as true a second later as it was the first time; "unreachable"
# (no route, refused, timed out) is the one failure a retry can cure.
#
# The first half feeds the classifier the texts the two transports really
# print -- the CLI git binary and libgit2 -- recorded from real runs and from
# the hosting sites' own wording. The second half runs real pushes against a
# bare repository this user cannot write and checks the verdict
# App::karr::Git::push_failure hands back, on both routes.

sub classify { return App::karr::Git::_classify_push_error( $_[0] ) }

# [ text, class, reason-regex, label ]
my @cases = (
    # --- denied, CLI ---------------------------------------------------
    [ "fatal: could not read Username for 'https://github.com': terminal prompts disabled",
      denied => qr/\Ano credentials for HTTPS\z/, 'https without credentials (the card text)' ],
    [ "fatal: could not read Username for 'http://git.example': terminal prompts disabled",
      denied => qr/\Ano credentials for HTTP\z/, 'http without credentials names HTTP, not HTTPS' ],
    [ "git\@github.com: Permission denied (publickey).\nfatal: Could not read from remote repository.\n"
    . "\nPlease make sure you have the correct access rights\nand the repository exists.",
      denied => qr/SSH key/, 'ssh: no key the remote accepts' ],
    [ "ERROR: The key you are authenticating with has been marked as read only.\n"
    . "fatal: Could not read from remote repository.",
      denied => qr/read-only/, 'ssh: a read-only deploy key' ],
    [ "remote: Permission to o/r.git denied to u.\n"
    . "fatal: unable to access 'https://github.com/o/r.git/': The requested URL returned error: 403",
      denied => qr/no write access/, 'https: GitHub permission denied plus 403 (specific rule wins)' ],
    [ "remote: Write access to repository not granted.\n"
    . "fatal: unable to access 'https://github.com/o/r.git/': The requested URL returned error: 403",
      denied => qr/no write access/, 'https: token without write access' ],
    [ "fatal: unable to access 'https://h/o/r.git/': The requested URL returned error: 403",
      denied => qr/403/, 'https: a bare 403' ],
    [ "remote: Invalid username or password.\nfatal: Authentication failed for 'https://h/o/r.git/'",
      denied => qr/authentication failed/, 'https: authentication failed' ],

    # --- denied, libgit2 -----------------------------------------------
    [ 'authentication required but no callback set',
      denied => qr/authentication failed/, 'libgit2: authentication required' ],
    [ 'too many redirects or authentication replays',
      denied => qr/authentication failed/, 'libgit2: authentication replays' ],
    [ 'failed to authenticate SSH session: Unable to send userauth-none request',
      denied => qr/SSH key/, 'libgit2: ssh session' ],

    # --- denied, a local remote this user cannot write -------------------
    [ "error: remote unpack failed: unable to create temporary object directory\n"
    . "error: failed to push some refs to '/srv/o.git'",
      denied => qr/cannot write the remote repository/, 'local remote, git 2.4x quarantine wording' ],
    [ "remote: error: insufficient permission for adding an object to repository database ./objects",
      denied => qr/cannot write the remote repository/, 'local remote, older "insufficient permission"' ],
    [ "failed to create temporary file '/srv/o.git/objects/pack/pack_git2_1': Permission denied",
      denied => qr/cannot write the remote repository/, 'local remote over libgit2' ],

    # --- unreachable -----------------------------------------------------
    [ "fatal: unable to access 'https://nohost.invalid/o/r.git/': Could not resolve host: nohost.invalid",
      unreachable => qr/could not be resolved/, 'name does not resolve' ],
    [ "fatal: unable to access 'https://h/o/r.git/': Failed to connect to h port 443: Connection refused",
      unreachable => qr/refused/, 'connection refused' ],
    [ "fatal: unable to access 'https://h/o/r.git/': Connection timed out after 300001 milliseconds",
      unreachable => qr/timed out/, 'connection timed out' ],
    [ "ssh: connect to host x port 22: Connection refused\n"
    . "fatal: Could not read from remote repository.\n\n"
    . "Please make sure you have the correct access rights\nand the repository exists.",
      unreachable => qr/refused/, 'ssh refused, ending on the generic access-rights sentence' ],
    [ "ssh: Could not resolve hostname nohost.invalid: Name or service not known\n"
    . "fatal: Could not read from remote repository.\n\n"
    . "Please make sure you have the correct access rights\nand the repository exists.",
      unreachable => qr/could not be resolved/, 'ssh name does not resolve, same trailing sentence' ],

    # --- anything else ---------------------------------------------------
    [ 'something nobody has classified',
      other => qr/\Asomething nobody has classified\z/, 'unrelated text is other, with its first line as reason' ],
    [ "fatal: Could not read from remote repository.\n\n"
    . "Please make sure you have the correct access rights\nand the repository exists.",
      other => qr/Could not read from remote repository/,
      'the generic ssh sentence alone proves nothing: other, not denied' ],
);

for my $case (@cases) {
    my ( $text, $class, $reason, $label ) = @$case;
    my ( $got, $why ) = classify($text);
    is $got, $class, "$label: class";
    like $why, $reason, "$label: reason";
}

subtest 'denied is told apart from unreachable when both words appear' => sub {
    # The wrong order would turn a refused ssh connection into "denied" (and
    # skip the retry that can cure it), or a 403 into "unreachable".
    my ($c) = classify("ssh: connect to host x port 22: Connection refused\n"
        . 'Please make sure you have the correct access rights');
    is $c, 'unreachable', 'a refused connection is not an access problem';
    ($c) = classify('Permission denied (publickey). Connection closed');
    is $c, 'denied', 'a refused key is not a connection problem';
};

subtest 'Git::Native::Error: is_auth alone gives denied' => sub {
    my $err = Git::Native::Error->new( code => GIT_EAUTH, message => 'something opaque from libgit2' );
    ok $err->is_auth, 'the double really is GIT_EAUTH';
    my ( $class, $reason ) = classify($err);
    is $class,  'denied',              'GIT_EAUTH is denied whatever the message says';
    is $reason, 'authentication failed', 'with the generic authentication reason';

    my $text = Git::Native::Error->new( code => -1, message => 'Connection refused' );
    ( $class ) = classify($text);
    is $class, 'unreachable', 'a generic GIT_ERROR is classified from its text';

    my $text403 = Git::Native::Error->new( code => -1, message => 'unexpected http status code: 403' );
    ( $class ) = classify($text403);
    is $class, 'denied', 'libgit2 reports 403 as the generic error; the text decides';
};

# ---------------------------------------------------------------------
# Real pushes against a bare repository this user cannot write.
# ---------------------------------------------------------------------
sub task {
    my ( $id, $title ) = @_;
    return App::karr::Task->new(
        id => $id, title => $title, status => 'todo',
        priority => 'high', class => 'standard', body => '',
    );
}

sub board_with_remote {
    my $work = tempdir( CLEANUP => 1 );
    system( 'git', 'init', '-q', '--bare', "$work/origin.git" );
    system("git clone -q '$work/origin.git' '$work/a' 2>/dev/null");
    system( 'git', '-C', "$work/a", 'config', 'user.email', 'a@karr.test' );
    system( 'git', '-C', "$work/a", 'config', 'user.name',  'agent-a' );
    my $git = App::karr::Git->new( dir => "$work/a" );
    $git->write_ref( 'refs/karr/config', "board:\n  name: demo\n" );
    $git->save_task_ref( task( 1, 'One' ) );
    return ( $work, $git );
}

sub set_writable {
    my ( $dir, $writable ) = @_;
    system( 'chmod', '-R', $writable ? 'u+w' : 'a-w', $dir );
}

subtest 'before any push there is no failure' => sub {
    my ( $work, $git ) = board_with_remote();
    is $git->push_failure, undef, 'push_failure is undef on a fresh object';
};

SKIP: {
    skip 'running as root: it ignores the read-only mode of the bare repository', 4
        if $> == 0;

    for my $route ( [ cli => 0 ], [ native => 1 ] ) {
        my ( $name, $native_only ) = @$route;
        subtest "a read-only bare origin is denied (route: $name)" => sub {
            local $ENV{KARR_NO_CLI_FALLBACK} = $native_only;
            my ( $work, $git ) = board_with_remote();
            set_writable( "$work/origin.git", 0 );
            my $ok = $git->push;
            set_writable( "$work/origin.git", 1 );

            ok !$ok, 'the push fails';
            my $failure = $git->push_failure;
            ok $failure, 'and says why';
            is $failure->{class},  'denied', 'the verdict is denied, not rejected or stale';
            is $failure->{remote}, 'origin', 'naming the remote';
            like $failure->{reason}, qr/cannot write the remote repository/,
                'with the reason a user can act on';
        };
    }

    subtest 'push_failure is cleared by a later push that lands' => sub {
        local $ENV{KARR_NO_CLI_FALLBACK} = 0;
        my ( $work, $git ) = board_with_remote();
        set_writable( "$work/origin.git", 0 );
        ok !$git->push, 'first push fails against the read-only origin';
        is $git->push_failure && $git->push_failure->{class}, 'denied', 'and is denied';

        set_writable( "$work/origin.git", 1 );
        ok $git->push, 'after the permission is back the push lands';
        is $git->push_failure, undef, 'and the old failure is gone';
    };

    subtest 'push_ref resets it as well' => sub {
        local $ENV{KARR_NO_CLI_FALLBACK} = 0;
        my ( $work, $git ) = board_with_remote();
        set_writable( "$work/origin.git", 0 );
        ok !$git->push, 'board push denied';
        ok $git->push_failure, 'failure recorded';
        set_writable( "$work/origin.git", 1 );

        $git->write_ref( 'refs/karr-x/y', "hi\n" );
        ok $git->push_ref('refs/karr-x/y'), 'a single-ref push lands';
        is $git->push_failure, undef, 'push_ref cleared the failure';
    };
}

done_testing;
