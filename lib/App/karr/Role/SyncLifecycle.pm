# ABSTRACT: Role providing sync lifecycle with retry and guard insurance

package App::karr::Role::SyncLifecycle;
our $VERSION = '0.304';
use Moo::Role;
use Carp qw( croak );
use App::karr::SyncGuard;

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
neutralises the guard after a successful push so it never pushes twice.

Commands that compose this role must also have a C<store> attribute (provided
by L<App::karr::Role::BoardDiscovery>) with a C<git> accessor.

=cut

=head1 METHODS

=head2 sync_before

    $self->sync_before;

Pulls refs from remote with 3 retries and clear error messages on failure.
Creates a L<App::karr::SyncGuard>, retains it on the object (so it outlives the
call and covers the command body), and also returns it for callers that want to
manage it explicitly. C<sync_after> clears it on a successful push.

=cut

sub sync_before {
    my ($self) = @_;
    my $git = $self->can('git') ? $self->git : $self->store->git;

    my $ok   = 0;
    my $err  = '';
    for my $attempt ( 1 .. 3 ) {
        print STDERR "Pull attempt $attempt of 3...\n";
        $ok = $git->pull;
        if ($ok) {
            print STDERR "Pull successful.\n" if $attempt > 1;
            last;
        }
        $err = "git pull failed: " . ( $git->last_error // 'unknown error' );
        print STDERR "  $err\n";
        sleep 1 if $attempt < 3;
    }
    croak "Pull failed after 3 attempts: $err\n" unless $ok;

    # Stash the guard on the object so it outlives sync_before's return and
    # covers the whole command body; sync_after neutralises it on success.
    my $guard = App::karr::SyncGuard->new( git => $git );
    $self->_sync_guard($guard);
    return $guard;
}

=head2 sync_after

    $self->sync_after;  # push with 3 retries
    $guard->done;       # mark guard as handled

Pushes refs to remote with 3 retries and clear error messages. After
successful push, mark the guard done so its DESTROY is a no-op.

=cut

sub sync_after {
    my ($self) = @_;
    my $git = $self->can('git') ? $self->git : $self->store->git;

    my $ok   = 0;
    my $err  = '';
    for my $attempt ( 1 .. 3 ) {
        print STDERR "Push attempt $attempt of 3...\n";
        $ok = $git->push;
        if ($ok) {
            print STDERR "Push successful.\n" if $attempt > 1;
            last;
        }
        $err = "git push failed: " . ( $git->last_error // 'unknown error' );
        print STDERR "  $err\n";
        sleep 1 if $attempt < 3;
    }
    croak "Push failed after 3 attempts. Local refs are intact.\n"
      . "Run 'karr sync' to retry.\n" unless $ok;

    # Push succeeded: neutralise the insurance guard so its DESTROY does not
    # fire a second, redundant push once the command body returns.
    if ( my $guard = $self->_sync_guard ) {
        $guard->done;
        $self->_sync_guard(undef);
    }
}

1;