# ABSTRACT: Push guard with automatic retry on scope exit

package App::karr::SyncGuard;
our $VERSION = '0.403';
use Moo;
use strict;
use warnings;
use App::karr::Git;

=head1 SYNOPSIS

    my $guard = $self->sync_before;  # git pull + return guard
    # ... command logic ...
    $self->sync_after;               # explicit push
    $guard->done;                    # mark guard as done (DESTROY no-ops)
    undef $guard;

    # If die/croak happens before sync_after:
    # Guard DESTROY retries the push 3 times, then warns with a clear error

=head1 DESCRIPTION

L<App::karr::SyncGuard> is created by L<App::karr::Role::SyncLifecycle/sync_before>.
It acts as an insurance policy: if the command body dies or croaks before
L<App::karr::Role::SyncLifecycle/sync_after> is called explicitly, the guard's
DESTROY runs sync_after with retry logic, ensuring refs are pushed even on failure.

The one case it deliberately does not retry is a guard that survives to Perl's
global destruction, which is where the CLI's own error handler leaves it.
L<App::karr::Git> is not re-entrant in that phase: pushing from there drove
L<FFI::Platypus>'s type parser into unbounded recursion until the machine was
out of memory. DESTROY therefore reports instead of pushing once
C<${^GLOBAL_PHASE}> is C<DESTRUCT>, and stays silent when
C<$App::karr::Git::WRITES> shows no ref was ever written. It reads that package
scalar rather than the C<git> attribute because blessed objects are destroyed
in undefined order in this phase. Local refs are untouched either way, so
C<karr sync> completes the push.

=cut

has git => (
    is       => 'ro',
    required => 1,
);

has _done => (
    is       => 'rw',
    default  => 0,
);

has quiet => (
    is      => 'ro',
    default => 0,
);

has _errors => (
    is       => 'ro',
    default  => sub { [] },
);

=head1 METHODS

=head2 done

    $guard->done;

Marks the guard as successfully completed. After this is called, the guard's
DESTROY is a no-op. Call this after L</sync_after> succeeds.

=cut

sub done {
    my ($self) = @_;
    $self->{_done} = 1;
}

=head2 errs

    my @errors = $guard->errs;

Returns the list of error messages from retry attempts.

=cut

sub errs {
    my ($self) = @_;
    return @{$self->{_errors}};
}

sub DESTROY {
    my ($self) = @_;
    return if $self->{_done};

    # A guard only reaped during global destruction cannot push. By then Perl
    # is destroying blessed objects in no defined order, and App::karr::Git's
    # libgit2/FFI layer is explicitly not re-entrant in that phase -- attempting
    # it recursed until the machine was out of memory (#34). Report instead of
    # pushing; the refs are still on disk.
    #
    # Nothing here may touch $self->{git}: it is a blessed object and may
    # already have been reaped, which is exactly what made this branch
    # nondeterministic before. $App::karr::Git::WRITES is a plain package
    # scalar, still readable throughout this phase, so "the body died before
    # writing anything" is decided on real state rather than on teardown order.
    if ( ${^GLOBAL_PHASE} eq 'DESTRUCT' ) {
        return unless $App::karr::Git::WRITES;
        warn "Push skipped: karr exited before the board was pushed.\n"
          . "Local refs are intact. Run 'karr sync' to push them.\n";
        return;
    }

    my $git  = $self->git;
    my $ok   = 0;
    my $err  = '';

    for my $attempt ( 1 .. 3 ) {
        # Retry-only (#27): the first attempt is silent; only announce retries,
        # and honour --quiet. Errors and the final guidance are always shown.
        print STDERR "Push retry $attempt of 3...\n"
          if $attempt > 1 && !$self->{quiet};
        $ok = $git->push;
        if ($ok) {
            $self->{_done} = 1;
            return;
        }
        # Native Git::Native/libgit2 ops set no shell exit code; the failure
        # detail lives in $git->last_error (see App::karr::Git).
        $err = "git push failed: " . ( $git->last_error // 'unknown error' );
        push @{$self->{_errors}}, $err;
        print STDERR "  $err\n";
        sleep 1 if $attempt < 3;
    }

    # Never die() here: DESTROY typically runs while another exception unwinds
    # the stack, where a die is turned into a swallowed "(in cleanup)" warning
    # (or lost entirely during global destruction), masking this message. Warn
    # so the "refs are intact, run karr sync" guidance always reaches STDERR.
    warn "Push failed after 3 attempts. Local refs are intact.\n"
      . "Run 'karr sync' to retry.\n"
      . "Errors: " . join( ', ', $self->errs ) . "\n";
}

1;