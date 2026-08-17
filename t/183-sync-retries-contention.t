use strict;
use warnings;
use Test::More;
use lib 't/lib';
use TestGit qw( require_git_c );
require_git_c();
use File::Temp qw( tempdir );
use App::karr::Git;
use App::karr::Task;
use App::karr::Cmd::Sync;
use App::karr::Role::SyncLifecycle;
use Git::Native::Remote;
use Git::Native::Remote::Result;

# Ticket #183, split out of #181. #181 taught App::karr::Role::SyncLifecycle
# and App::karr::SyncGuard that a push the far side rejected because another
# push reached the ref first is contention, not a refusal, and that the three
# attempts they already make are exactly what it is for.
#
# `karr sync` went through neither. App::karr::Cmd::Sync called $git->pull and
# $git->push once each and died on a false return:
#
#     $git->push
#         or die "Push failed: " . ( $git->last_error // 'unknown error' ) . "\n";
#
# So the one command karr points every failed sync at -- "Local refs are
# intact. Run 'karr sync' to retry." -- was the only command with no retry and
# no idea what contention is. Two agents syncing in the same moment, or one
# syncing while another writes, got the spurious failure #181 removed
# everywhere else; measured there, contention hit 4 to 5 of 8 parallel writers
# in every run against a real git daemon.
#
# The fix is not a second copy of the retry loop: Cmd::Sync composes
# App::karr::Role::BoardAccess, which composes SyncLifecycle, so the role was
# already there and simply unused. What this file pins is that both halves go
# through it -- and that going through it did not cost the two safety valves
# (--prune, --accept-foreign-board) or turn --pull into something that pushes.

sub task {
    my ( $id, $title ) = @_;
    return App::karr::Task->new(
        id => $id, title => $title, status => 'todo',
        priority => 'high', class => 'standard', body => '',
    );
}

# A git double shaped like the one #181 drives the role with, plus the three
# things Cmd::Sync asks before it syncs anything. pull records the options it
# was handed on every attempt, which is how the safety valves are checked.
{
    package SyncGit;
    sub new {
        my ( $class, %arg ) = @_;
        return bless {
            pulls        => 0,
            pushes       => 0,
            fleet_pulls  => 0,
            fleet_pushes => 0,
            pull_until   => $arg{pull_until} // 1,
            push_until   => $arg{push_until} // 1,
            refuse       => $arg{refuse} // 0,
            pull_opts    => [],
        }, $class;
    }
    sub is_repo         { 1 }
    sub git_user_email  { 'agent@karr.test' }
    sub git_user_name   { 'agent' }

    sub pull {
        my ( $self, $remote, %opt ) = @_;
        CORE::push @{ $self->{pull_opts} }, \%opt;
        return ++$self->{pulls} >= $self->{pull_until} ? 1 : 0;
    }
    sub push {
        my ($self) = @_;
        return ++$self->{pushes} >= $self->{push_until} ? 1 : 0;
    }

    # The fleet-coordination half (#190). Counted apart from the board's so
    # the direction flags below can be checked on both namespaces: `karr sync`
    # carries refs/karr-foundation/* through the same role, and --pull that
    # pushed the chain would be the same bug on the other namespace.
    sub pull_foundation { return ++$_[0]{fleet_pulls} && 1 }
    sub push_foundation { return ++$_[0]{fleet_pushes} && 1 }

    # Borrowed from the real classification rather than answering the question
    # itself, so the reason strings are pinned here too.
    sub push_rejections {
        my ($self) = @_;
        return [ {
            ref    => 'refs/karr/config',
            reason => 'pre-receive hook declined',
        } ] if $self->{refuse};
        return [] if $self->{pushes} >= $self->{push_until};
        return [ {
            ref    => 'refs/karr/tasks/1/data',
            reason => "failed to write reference 'refs/karr/tasks/1/data': "
                    . 'a reference with that name already exists.',
        } ];
    }
    sub push_contention { App::karr::Git::push_contention(@_) }
    sub last_error      { 'SIMULATED-TRANSPORT-ERROR' }

    sub pulls        { $_[0]{pulls} }
    sub pushes       { $_[0]{pushes} }
    sub fleet_pulls  { $_[0]{fleet_pulls} }
    sub fleet_pushes { $_[0]{fleet_pushes} }
    sub pull_opts    { $_[0]{pull_opts} }
}

# Runs one `karr sync` in process with both handles captured. The command
# object is freed *inside* the capture, so a SyncGuard this command left armed
# fires its insurance push where the double can count it and where its output
# cannot escape onto the real STDERR -- which is how the --pull case below
# checks that nothing pushes without reaching into the role's internals.
sub run_sync {
    my (%opt) = @_;
    my $git = delete $opt{git};
    my ( $out, $err, $exception ) = ( '', '', undef );
    {
        local *STDOUT;
        local *STDERR;
        open STDOUT, '>', \$out or die "cannot redirect STDOUT: $!";
        open STDERR, '>', \$err or die "cannot redirect STDERR: $!";
        my $cmd = App::karr::Cmd::Sync->new( git => $git, %opt );
        $exception = do { local $@; eval { $cmd->execute; 1 } ? undef : $@ };
        undef $cmd;
    }
    return { stdout => $out, stderr => $err, error => $exception };
}

# ---------------------------------------------------------------------
# The push half: the regression #183 is about.
# ---------------------------------------------------------------------
subtest 'a contended push is retried instead of failing the sync' => sub {
    my $git = SyncGit->new( push_until => 2 );
    my $r   = run_sync( git => $git );

    is $r->{error}, undef,
        'karr sync no longer fails because somebody else pushed first';
    is $git->pushes, 2, 'the second attempt is made, and lands';
    like $r->{stderr}, qr/Push retry 2 of 3/, 'the retry is announced';
    like $r->{stderr}, qr/Push succeeded/,    'and reported as succeeding';
    like $r->{stdout}, qr/Done\./,            'the command completes';
};

subtest 'a push the remote refused still ends the sync at once (#84)' => sub {
    my $git = SyncGit->new( push_until => 99, refuse => 1 );
    my $r   = run_sync( git => $git );

    is $git->pushes, 1, 'a declining hook is taken as the answer it is';
    like $r->{error}, qr/Push rejected by the remote/,
        'and the sync fails with the refusal wording';
    like $r->{stderr}, qr/SIMULATED-TRANSPORT-ERROR/,
        'the error the remote gave is still on STDERR, not swallowed';
    unlike $r->{stderr}, qr/Push retry/,
        'with no pointless retry announcements';
    unlike $r->{stdout}, qr/Done\./, 'and no "Done."';
};

subtest 'contention that outlives the retries fails as a push failure' => sub {
    my $git = SyncGit->new( push_until => 99 );
    my $r   = run_sync( git => $git );

    is $git->pushes, 3, 'all three attempts are spent on it';
    like $r->{error}, qr/Push failed after 3 attempts/,
        'a lost race is reported as a failure to push';
    unlike $r->{error}, qr/Push rejected by the remote/,
        'never as the remote saying no';
};

# ---------------------------------------------------------------------
# The pull half: same treatment, per the ticket.
# ---------------------------------------------------------------------
subtest 'a failed pull is retried instead of failing the sync' => sub {
    my $git = SyncGit->new( pull_until => 2 );
    my $r   = run_sync( git => $git );

    is $r->{error}, undef, 'the pull recovers on the retry';
    is $git->pulls, 2, 'the second pull attempt is made';
    like $r->{stderr}, qr/Pull retry 2 of 3/, 'the pull retry is announced';
    is $git->pushes, 1, 'and the push half still runs afterwards';
    like $r->{stdout}, qr/Done\./, 'the command completes';
};

subtest 'a pull that never comes back fails after three attempts' => sub {
    my $git = SyncGit->new( pull_until => 99 );
    my $r   = run_sync( git => $git );

    is $git->pulls, 3, 'three pull attempts were really made';
    like $r->{error}, qr/Pull failed after 3 attempts/, 'and then it gives up';
    like $r->{stderr}, qr/SIMULATED-TRANSPORT-ERROR/,
        'the transport error is on STDERR';
    is $git->pushes, 0, 'nothing is pushed over a board that was never pulled';
};

# ---------------------------------------------------------------------
# The safety valves must survive the new route (#82, #95).
# ---------------------------------------------------------------------
subtest 'the accept flags are passed through, and never implied' => sub {
    my $plain = SyncGit->new;
    run_sync( git => $plain );
    is_deeply $plain->pull_opts, [ { accept_wipe => 0, accept_foreign => 0 } ],
        'a plain sync asks for neither a wipe nor a foreign board';

    my $pruning = SyncGit->new;
    run_sync( git => $pruning, prune => 1 );
    is_deeply $pruning->pull_opts, [ { accept_wipe => 1, accept_foreign => 0 } ],
        '--prune reaches Git::pull as accept_wipe, and drags nothing with it';

    my $foreign = SyncGit->new;
    run_sync( git => $foreign, accept_foreign_board => 1 );
    is_deeply $foreign->pull_opts, [ { accept_wipe => 0, accept_foreign => 1 } ],
        '--accept-foreign-board reaches it as accept_foreign, alone';
};

subtest 'a retried pull is retried with the same permissions, not wider' => sub {
    my $git = SyncGit->new( pull_until => 3, refuse => 0 );
    run_sync( git => $git, prune => 1 );

    is scalar @{ $git->pull_opts }, 3, 'three attempts, three option sets';
    is_deeply $git->pull_opts,
        [ ( { accept_wipe => 1, accept_foreign => 0 } ) x 3 ],
        'every attempt carries exactly what the user asked for';
};

subtest 'a command that pulls without asking gets neither valve' => sub {
    my $git = SyncGit->new;
    {
        package PlainBoard;
        use Moo;
        use MooX::Options;
        with 'App::karr::Role::SyncLifecycle';
        has git => ( is => 'ro', required => 1 );
    }
    my $board = PlainBoard->new( git => $git, quiet => 1 );
    my $guard = $board->sync_before;
    $guard->done;

    is_deeply $git->pull_opts, [ {} ],
        'sync_before called bare forwards no accept flags at all, so every '
      . 'writing command keeps the refusals';
};

# ---------------------------------------------------------------------
# --pull and --push keep meaning exactly what they meant.
# ---------------------------------------------------------------------
subtest '--pull pulls and does not push, not even at teardown' => sub {
    my $git = SyncGit->new;
    my $r   = run_sync( git => $git, pull => 1 );

    is $r->{error}, undef, 'the pull-only sync succeeds';
    is $git->pulls,  1, 'it pulled';
    # The command object was freed inside run_sync's capture, so an armed
    # SyncGuard would have pushed by now. --pull says do not push.
    is $git->pushes, 0, 'and nothing pushed, including no insurance push';
    unlike $r->{stderr}, qr{Pushing refs/karr/}, 'no push announced either';
    is $git->fleet_pulls,  1, 'the fleet namespace was pulled too (#190)';
    is $git->fleet_pushes, 0, 'and not pushed, same as the board';
};

subtest '--push pushes and does not pull' => sub {
    my $git = SyncGit->new( push_until => 2 );
    my $r   = run_sync( git => $git, push => 1 );

    is $r->{error}, undef, 'a contended push-only sync recovers too';
    is $git->pulls,  0, 'it did not pull';
    is $git->pushes, 2, 'and the push got its retry';
    is $git->fleet_pulls,  0, 'the fleet namespace was not pulled either';
    is $git->fleet_pushes, 1, 'and it was pushed, same as the board (#190)';
};

subtest '--quiet silences the banners and the retries, never the errors' => sub {
    my $git = SyncGit->new( push_until => 99, refuse => 1 );
    my $r   = run_sync( git => $git, quiet => 1 );

    unlike $r->{stderr}, qr{Pulling refs/karr/}, '--quiet drops the pull banner';
    unlike $r->{stderr}, qr{Pushing refs/karr/}, '--quiet drops the push banner';
    like $r->{stderr}, qr/SIMULATED-TRANSPORT-ERROR/,
        'but the error still reaches STDERR';
    like $r->{error}, qr/Push rejected by the remote/,
        'and the verdict is still raised';
};

# ---------------------------------------------------------------------
# End to end: a real repository, a real remote, the real App::karr::Git, and
# the rejection libgit2's local transport actually produces when two pushes
# race for the same new ref.
# ---------------------------------------------------------------------
subtest 'a real contended push lands on the retry and reaches the remote' => sub {
    my $work = tempdir( CLEANUP => 1 );
    system( 'git', 'init', '-q', '--bare', "$work/origin.git" );
    system("git clone -q '$work/origin.git' '$work/a' 2>/dev/null");
    system( 'git', '-C', "$work/a", 'config', 'user.email', 'a@karr.test' );
    system( 'git', '-C', "$work/a", 'config', 'user.name',  'agent-a' );

    my $git = App::karr::Git->new( dir => "$work/a" );
    $git->write_ref( 'refs/karr/config', "board:\n  name: demo\n" );
    $git->save_task_ref( task( 1, 'One' ) );

    # First push loses the race the way libgit2's local transport reports it;
    # the second is the genuine article.
    my $pushes = 0;
    my $orig   = \&Git::Native::Remote::push;
    no warnings 'redefine';
    local *Git::Native::Remote::push = sub {
        my ( $remote, @rest ) = @_;
        return Git::Native::Remote::Result->new(
            updated  => [],
            rejected => [ {
                ref    => 'refs/karr/tasks/1/data',
                reason => "failed to write reference 'refs/karr/tasks/1/data': "
                        . 'a reference with that name already exists.',
            } ],
        ) if ++$pushes == 1;
        return $orig->( $remote, @rest );
    };

    my $r = run_sync( git => $git, push => 1 );

    is $r->{error}, undef, 'karr sync --push survives the lost race';
    is $pushes, 2, 'because it pushed again';
    like $r->{stderr}, qr/Push retry 2 of 3/, 'announcing the retry';
    like $r->{stdout}, qr/Done\./, 'and finishing';

    my @refs = `git -C '$work/origin.git' for-each-ref --format='%(refname)' refs/karr/`;
    chomp @refs;
    ok scalar( grep { $_ eq 'refs/karr/config' } @refs ),
        'and the board really is on the remote, not merely reported as pushed';
    ok scalar( grep { $_ eq 'refs/karr/tasks/1/data' } @refs ),
        'the contended ref included';
};

done_testing;
