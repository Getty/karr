# ABSTRACT: Role providing sync lifecycle with retry and guard insurance

package App::karr::Role::SyncLifecycle;
our $VERSION = '0.403';
use Moo::Role;
use MooX::Options;
use Carp qw( croak );
use App::karr::SyncGuard;

option quiet => (
    is  => 'ro',
    doc => 'Suppress sync progress and retry messages (errors are still shown)',
);

# Holds the SyncGuard for the duration of a command so its DESTROY-insurance
# actually spans the command body. sync_before stashes it here; sync_after
# neutralises it after a successful push. Without this the guard returned by
# sync_before was discarded in void context and pushed prematurely (#28).
has _sync_guard => (
    is      => 'rw',
    default => sub { undef },
);

=head1 DESCRIPTION

This role provides C<sync_before> and C<sync_after> methods that wrap Git pull
and push operations with retry logic. C<sync_before> creates a
L<App::karr::SyncGuard> and retains it on the object as insurance: if the
command body dies or croaks before C<sync_after> runs, the guard's DESTROY
pushes with 3 retries. Because the guard is held by the role (not by the
caller), commands may call both methods in void context; C<sync_after>
neutralises the guard so it never pushes twice.

Holding the guard on the command object is also why the CLI cannot rely on
DESTROY alone: L<MooX::Cmd>'s command chain keeps that object alive past
F<bin/karr>'s error handler, so on the die path the guard is only reaped in
global destruction, where pushing is forbidden. F<bin/karr> therefore drains
L<App::karr::SyncGuard/flush_armed> from an C<END> block.

Commands that compose this role must also have a C<store> attribute (provided
by L<App::karr::Role::BoardDiscovery>) with a C<git> accessor.

=cut

=head1 METHODS

=head2 sync_before

    $self->sync_before;

Pulls refs from remote with up to 3 attempts. Output is retry-only: the first
attempt is silent, retries are announced from attempt 2 ("Pull retry 2 of
3..."), and errors always reach STDERR. C<--quiet> additionally suppresses the
retry announcements but never the errors. Creates a L<App::karr::SyncGuard>,
retains it on the object (so it outlives the call and covers the command body),
and also returns it for callers that want to manage it explicitly. C<sync_after>
clears it on a successful push.

=cut

sub sync_before {
    my ($self) = @_;
    my $git = $self->can('git') ? $self->git : $self->store->git;

    my $ok   = 0;
    my $err  = '';
    for my $attempt ( 1 .. 3 ) {
        # Retry-only: attempt 1 is silent; only announce the actual retries.
        print STDERR "Pull retry $attempt of 3...\n"
          if $attempt > 1 && !$self->quiet;
        $ok = $git->pull;
        if ($ok) {
            print STDERR "Pull succeeded.\n" if $attempt > 1 && !$self->quiet;
            last;
        }
        # Errors always reach STDERR, even under --quiet.
        $err = "git pull failed: " . ( $git->last_error // 'unknown error' );
        print STDERR "  $err\n";
        sleep 1 if $attempt < 3;
    }
    croak "Pull failed after 3 attempts: $err\n" unless $ok;

    # Stash the guard on the object so it outlives sync_before's return and
    # covers the whole command body; sync_after neutralises it on success.
    my $guard = App::karr::SyncGuard->new( git => $git, quiet => $self->quiet );
    $self->_sync_guard($guard);
    return $guard;
}

=head2 sync_after

    $self->sync_after;  # push with up to 3 attempts

Pushes refs to remote with up to 3 attempts, using the same retry-only output
convention as L</sync_before> (silent first attempt, retries announced from
attempt 2, errors always on STDERR, C<--quiet> silencing only the
announcements). It marks the retained guard done and clears it on both
outcomes: after a successful push there is nothing left to insure, and after a
failed one the guard's three attempts have just been spent, so re-running them
from L<App::karr::SyncGuard/flush_armed> would only repeat the failure.

=cut

sub sync_after {
    my ($self) = @_;
    my $git = $self->can('git') ? $self->git : $self->store->git;

    my $ok   = 0;
    my $err  = '';
    for my $attempt ( 1 .. 3 ) {
        # Retry-only: attempt 1 is silent; only announce the actual retries.
        print STDERR "Push retry $attempt of 3...\n"
          if $attempt > 1 && !$self->quiet;
        $ok = $git->push;
        if ($ok) {
            print STDERR "Push succeeded.\n" if $attempt > 1 && !$self->quiet;
            last;
        }
        # Errors always reach STDERR, even under --quiet.
        $err = "git push failed: " . ( $git->last_error // 'unknown error' );
        print STDERR "  $err\n";
        sleep 1 if $attempt < 3;
    }
    # Neutralise the insurance guard on both outcomes.
    #
    # On success: so its DESTROY does not fire a second, redundant push once
    # the command body returns (#28).
    #
    # On failure: the three attempts the insurance would make have just been
    # made and the croak below carries the same "run karr sync" guidance, so
    # leaving the guard armed would only make the END flush in bin/karr (#37)
    # repeat the identical failing push, doubling both the delay and the noise
    # on an already-failing command.
    $self->_release_guard;

    croak "Push failed after 3 attempts. Local refs are intact.\n"
      . "Run 'karr sync' to retry.\n" unless $ok;
}

sub _release_guard {
    my ($self) = @_;
    if ( my $guard = $self->_sync_guard ) {
        $guard->done;
        $self->_sync_guard(undef);
    }
    return;
}

1;