# ABSTRACT: Lock management via Git refs

package App::karr::Lock;
our $VERSION = '0.403';
use strict;
use warnings;
use App::karr::Git;

=head1 SYNOPSIS

    my $lock = App::karr::Lock->new(git => $git);
    my ($ok, $msg) = $lock->acquire(12, 'agent@example.com');

=head1 DESCRIPTION

L<App::karr::Lock> manages lightweight per-task locks stored in Git refs. It is
used by commands such as C<karr pick> to avoid concurrent agents selecting the
same task at the same time.

=cut

sub new {
    my ( $class, %args ) = @_;
    my $git = $args{git};
    unless ($git) {
        $git = App::karr::Git->new( dir => $args{dir} // '.' );
    }
    return bless {
        git     => $git,
        task_id => $args{task_id},
    }, $class;
}

sub task_id { shift->{task_id} }
sub git     { shift->{git} }

sub ref_name {
    my ( $self, $task_id ) = @_;
    $task_id //= $self->task_id;
    return "refs/karr/tasks/$task_id/lock";
}

sub get {
    my ( $self, $task_id ) = @_;
    my $ref = $self->ref_name($task_id);
    my $content = $self->git->read_ref($ref);
    return $content;
}

# Acquisition is one compare-and-swap per attempt, never a read followed by an
# unguarded write. The old version checked the ref and then wrote it, so every
# contender passed the check and every contender was told it had the lock --
# 16 forked agents, 16 "acquired" (#46).
#
# The OID read here is what the write is guarded against, so any outcome other
# than "the ref is still exactly as I judged it" fails and is retried against a
# fresh read. That is also what makes a future expiry/steal safe: a holder that
# refreshes its lock between the moment we decide it is stale and the moment we
# take it over moves the ref, and the takeover loses instead of overwriting a
# live lock. (App::karr::Lock has no TTL yet; that is the orphaned-locks
# ticket. This is the primitive it will need.)
sub acquire {
    my ( $self, $task_id, $email ) = @_;
    $task_id //= $self->task_id;
    my $ref = $self->ref_name($task_id);
    my $git = $self->git;

    return $git->retry_contended( "the lock on task $task_id", sub {
        my ( $oid, $current ) = $git->read_ref_with_oid($ref);

        # Held by somebody else: a final answer, not contention. Say so rather
        # than dying, which is what the raw libgit2 lock error used to do.
        return ( 0, "locked by $current" )
            if defined $oid && length $current && $current ne $email;

        # $oid undef => create-if-absent, the exclusive case. $oid set => this
        # is our own lock and we are refreshing it, guarded against the holder
        # having changed since the read above.
        return () unless $git->write_ref_cas( $ref, $email, $oid );
        return ( 1, "acquired" );
    } );
}

sub release {
    my ( $self, $task_id, $email ) = @_;
    $task_id //= $self->task_id;
    my $ref = $self->ref_name($task_id);

    my $current = $self->get($task_id);
    if ( $current && $current ne $email ) {
        return ( 0, "locked by $current" );
    }

    $self->git->delete_ref($ref);
    return ( 1, "released" );
}

1;
