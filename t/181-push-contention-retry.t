use strict;
use warnings;
use Test::More;
use lib 't/lib';
use TestGit qw( require_git_c );
require_git_c();
use File::Temp qw( tempdir );
use App::karr::Git;
use App::karr::SyncGuard;
use App::karr::Task;
use App::karr::Role::SyncLifecycle;
use Git::Native::Remote;
use Git::Native::Remote::Result;

# Ticket #181: `karr create` wrote its card, pushed it, and then exited
# non-zero anyway whenever another push was in flight at the same time. The
# push came back rejected per ref -- and #84 made a per-ref rejection the
# server's final answer, so the retry loop was skipped and the command failed
# on a card that was on the board and on the remote.
#
# The reason strings are the whole story. A rejection that says "another push
# got to this ref first" is not a refusal:
#
#   libgit2's local transport (a bare repo by path or file://) creates a
#   ref it has just looked up and not found, *without* force, so a ref
#   another push created in between fails with "a reference with that name
#   already exists" -- although karr's board refspec is +refs/karr/*.
#
#   git-receive-pack -- every real ssh/https/git:// remote -- fails the ref
#   transaction and reports "failed to update ref".
#
# This is not a local-transport quirk, which is what decided that the fix
# belongs in the classification rather than in a new retry mechanism: 8
# parallel creates in one clone left 3 of 10 runs with a failed create against
# a path remote, and 4 to 5 of 8 creates failing in *every* run against a real
# `git daemon`, whose ref transaction is atomic and so takes the whole push
# down over one contended ref. Both are gone once the existing retry loop is
# allowed to have them.
#
# What must not come back is #84: a pre-receive hook, a protected ref, a
# non-fast-forward are still the server's final answer, retried never. The
# line between the two is App::karr::Git/push_contention, and a push with one
# real refusal among its contended refs stays final.

sub task {
    my ( $id, $title ) = @_;
    return App::karr::Task->new(
        id => $id, title => $title, status => 'todo',
        priority => 'high', class => 'standard', body => '',
    );
}

# A bare origin plus a clone with a board written into refs/karr/* and nothing
# pushed yet -- enough for push() to have something to be rejected.
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

# Runs one push whose Result carries @$rejected, the way libgit2 hands it back.
sub push_rejecting {
    my ( $git, $rejected ) = @_;
    no warnings 'redefine';
    local *Git::Native::Remote::push = sub {
        return Git::Native::Remote::Result->new(
            updated => [], rejected => $rejected );
    };
    return $git->push;
}

# ---------------------------------------------------------------------
# The classification itself, on the object that owns it.
# ---------------------------------------------------------------------
subtest 'the local transport wording is contention, not a refusal' => sub {
    my ( $work, $git ) = board_with_remote();

    my $ok = push_rejecting( $git, [ {
        ref    => 'refs/karr/tasks/1/data',
        reason => "failed to write reference 'refs/karr/tasks/1/data': "
                . 'a reference with that name already exists.',
    } ] );

    ok !$ok, 'the push still fails -- the refs did not land';
    ok @{ $git->push_rejections }, 'and the rejection is still reported per ref';
    ok $git->push_contention,
        'but it is named as contention, so the caller may push again';
};

subtest 'receive-pack wording is contention too' => sub {
    my ( $work, $git ) = board_with_remote();

    my $ok = push_rejecting( $git, [
        { ref => 'refs/karr/config',        reason => 'failed to update ref' },
        { ref => 'refs/karr/tasks/1/data',  reason => 'failed to update ref' },
    ] );

    ok !$ok, 'the push fails';
    ok $git->push_contention,
        'the wording a real remote sends is recognised as well as libgit2 own';
};

subtest 'a genuine refusal is still final (#84)' => sub {
    my ( $work, $git ) = board_with_remote();

    push_rejecting( $git,
        [ { ref => 'refs/karr/config', reason => 'pre-receive hook declined' } ] );
    ok !$git->push_contention, 'a declining hook is not contention';

    push_rejecting( $git,
        [ { ref => 'refs/karr/config', reason => 'non-fast-forward' } ] );
    ok !$git->push_contention, 'nor is a non-fast-forward';

    push_rejecting( $git,
        [ { ref => 'refs/karr/config', reason => 'protected ref' } ] );
    ok !$git->push_contention, 'nor a protected ref';
};

subtest 'one refusal among contended refs makes the whole push final' => sub {
    my ( $work, $git ) = board_with_remote();

    push_rejecting( $git, [
        { ref => 'refs/karr/tasks/1/data', reason => 'failed to update ref' },
        { ref => 'refs/karr/config',       reason => 'pre-receive hook declined' },
    ] );

    ok !$git->push_contention,
        'pushing again cannot change the answer for the protected ref';
};

subtest 'a push nobody rejected is not contention either' => sub {
    my ( $work, $git ) = board_with_remote();

    ok $git->push, 'the push lands';
    ok !$git->push_contention, 'nothing was rejected, so there is nothing to retry';
};

# ---------------------------------------------------------------------
# The retry loops. The duck-typed gits below borrow the real classification
# rather than answering the question themselves -- push_contention reads
# nothing but push_rejections -- so these pin the reason strings too.
# ---------------------------------------------------------------------
{
    package ContendedGit;
    sub new {
        my ( $class, %arg ) = @_;
        return bless { pushes => 0, until => $arg{until} // 2 }, $class;
    }
    sub pull { 1 }
    sub push {
        my ($self) = @_;
        return ++$self->{pushes} >= $self->{until} ? 1 : 0;
    }
    sub push_rejections {
        my ($self) = @_;
        return [] if $self->{pushes} >= $self->{until};
        return [ {
            ref    => 'refs/karr/tasks/1/data',
            reason => "failed to write reference 'refs/karr/tasks/1/data': "
                    . 'a reference with that name already exists.',
        } ];
    }
    sub push_contention { App::karr::Git::push_contention(@_) }
    sub last_error {
        "the remote 'origin' rejected 1 of 7 refs:\n"
      . "    refs/karr/tasks/1/data: failed to write reference "
      . "'refs/karr/tasks/1/data': a reference with that name already exists."
    }
    sub pushes { $_[0]{pushes} }
}

{
    package RefusingGit;
    sub new { bless { pushes => 0 }, shift }
    sub pull { 1 }
    sub push { my ($self) = @_; $self->{pushes}++; return 0 }
    sub push_rejections {
        [ { ref => 'refs/karr/config', reason => 'pre-receive hook declined' } ]
    }
    sub push_contention { App::karr::Git::push_contention(@_) }
    sub last_error {
        "the remote 'origin' rejected all 1 ref:\n"
      . '    refs/karr/config: pre-receive hook declined'
    }
    sub pushes { $_[0]{pushes} }
}

{
    package ContendBoard;
    use Moo;
    use MooX::Options;
    with 'App::karr::Role::SyncLifecycle';
    has git => ( is => 'ro', required => 1 );
}

sub capture_stderr {
    my ($code) = @_;
    my ( $buf, $err ) = ( '', undef );
    {
        local *STDERR;
        open STDERR, '>', \$buf or die "cannot redirect STDERR: $!";
        $err = do { local $@; eval { $code->(); 1 } ? undef : $@ };
    }
    return ( $buf, $err );
}

subtest 'sync_after retries a contended push instead of failing the command' => sub {
    my $git = ContendedGit->new( until => 2 );
    my ( $stderr, $err ) = capture_stderr( sub {
        my $board = ContendBoard->new( git => $git );
        $board->sync_before;
        $board->sync_after;
    } );

    is $err, undef,
        'the command that wrote the card does not fail on somebody else race';
    is $git->pushes, 2, 'the second attempt is made, and lands';
    like $stderr, qr/Push succeeded/, 'and the retry is reported as succeeding';
};

subtest 'sync_after still stops dead on a refusal (#84)' => sub {
    my $git = RefusingGit->new;
    my ( $stderr, $err ) = capture_stderr( sub {
        my $board = ContendBoard->new( git => $git );
        $board->sync_before;
        $board->sync_after;
    } );

    is $git->pushes, 1, 'the refusal is taken as the answer it is';
    like $err, qr/Push rejected by the remote/, 'and the command fails loudly';
    unlike $stderr, qr/Push retry/, 'with no pointless retry announcements';
};

subtest 'contention that outlives the retries is an ordinary push failure' => sub {
    my $git = ContendedGit->new( until => 99 );
    my ( $stderr, $err ) = capture_stderr( sub {
        my $board = ContendBoard->new( git => $git );
        $board->sync_before;
        $board->sync_after;
    } );

    is $git->pushes, 3, 'all three attempts are spent on it';
    like $err, qr/Push failed after 3 attempts/,
        'and the verdict is the one that fits: nothing refused it, it kept losing';
    like $err, qr/Run 'karr sync' to retry/,
        'so the advice is the true one, not "it would be refused again"';
    unlike $err, qr/Push rejected by the remote/,
        'a lost race is not reported as the remote saying no';
};

# ---------------------------------------------------------------------
# The insurance push (App::karr::SyncGuard) -- the path that runs after a
# command has already died, and the board last chance to reach the remote.
# ---------------------------------------------------------------------
subtest 'the insurance push retries contention' => sub {
    local $App::karr::Git::WRITES = 1;
    my $git = ContendedGit->new( until => 2 );
    # Held in a lexical: the registry keeps only a weak reference.
    my $guard = App::karr::SyncGuard->new( git => $git, quiet => 1 );

    my ( $stderr, $err ) =
        capture_stderr( sub { App::karr::SyncGuard->flush_armed } );

    is $err, undef, 'the flush never dies';
    is $git->pushes, 2, 'and the second attempt puts the board on the remote';
    unlike $stderr, qr/Push rejected by the remote/,
        'nothing is reported as refused';
};

subtest 'the insurance push still does not retry a refusal (#84, #96)' => sub {
    local $App::karr::Git::WRITES = 1;
    my $git = RefusingGit->new;
    my $guard = App::karr::SyncGuard->new( git => $git, quiet => 1 );

    my ($stderr) = capture_stderr( sub { App::karr::SyncGuard->flush_armed } );

    is $git->pushes, 1, 'one attempt, because the answer was given';
    like $stderr, qr/Push rejected by the remote/, 'named for what it is';
    like $stderr, qr/would only be refused again/, 'with the reason retrying is pointless';
};

subtest 'unwinnable contention warns with the retry advice, not the refusal one' => sub {
    local $App::karr::Git::WRITES = 1;
    my $git = ContendedGit->new( until => 99 );
    my $guard = App::karr::SyncGuard->new( git => $git, quiet => 1 );

    my ($stderr) = capture_stderr( sub { App::karr::SyncGuard->flush_armed } );

    is $git->pushes, 3, 'three attempts were really made';
    like $stderr, qr/Push failed after 3 attempts/, 'reported as a failure to push';
    like $stderr, qr/Run 'karr sync' to retry/,
        'and karr sync is worth running, unlike after a refusal';
    unlike $stderr, qr/would only be refused again/,
        'the refusal wording does not leak onto a race';
};

done_testing;
