# ABSTRACT: Lock management via Git refs

package App::karr::Lock;
our $VERSION = '0.403';
use strict;
use warnings;
use App::karr::Git;

=head1 SYNOPSIS

    my $lock = App::karr::Lock->new(git => $git, ttl => 300);
    my ($ok, $msg) = $lock->acquire(12, 'agent@example.com');

=head1 DESCRIPTION

L<App::karr::Lock> manages lightweight per-task locks stored in Git refs. It is
used by commands such as C<karr pick> to avoid concurrent agents selecting the
same task at the same time.

The lock is an optimisation, not the thing that makes C<karr pick> exclusive.
Its holder identity is the clone's C<user.email>, which every agent on one
machine shares, so it cannot separate them from each other at all; what actually
binds a pick is the compare-and-swap on the task card itself
(L<App::karr::BoardStore/save_task_cas>). What the lock buys is that agents do
not all pile onto the same candidate and lose the same race.

=head2 Expiry

A lock has a TTL, because an agent that dies between C<acquire> and C<release>
otherwise leaves a ref that no future run will ever clear -- and that task then
stays unpickable forever, with no way out from inside karr (#45). Age is the
committer time of the commit the lock ref points at, so it needs no payload of
its own and travels with the ref.

A lock past its TTL may be taken over. The takeover is itself a compare-and-swap
against the OID whose age was judged, so a holder that refreshes its lock in
between wins and is never silently evicted. The TTL is deliberately B<not>
C<claim_timeout>: see L<App::karr::Cmd::Pick>.

=cut

# Fallback when the caller names no TTL. App::karr::Cmd::Pick passes the board's
# `lock_timeout` instead; this only covers direct programmatic use.
use constant DEFAULT_TTL => 300;

sub new {
    my ( $class, %args ) = @_;
    my $git = $args{git};
    unless ($git) {
        $git = App::karr::Git->new( dir => $args{dir} // '.' );
    }
    return bless {
        git     => $git,
        task_id => $args{task_id},
        ttl     => $args{ttl},
    }, $class;
}

sub task_id { shift->{task_id} }
sub git     { shift->{git} }

sub ttl {
    my ($self) = @_;
    return defined $self->{ttl} ? $self->{ttl} : DEFAULT_TTL;
}

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
# fresh read. That is also what makes the expiry/steal below safe: a holder that
# refreshes its lock between the moment we decide it is stale and the moment we
# take it over moves the ref, and the takeover loses instead of overwriting a
# live lock.
sub acquire {
    my ( $self, $task_id, $email ) = @_;
    $task_id //= $self->task_id;
    my $ref = $self->ref_name($task_id);
    my $git = $self->git;

    return $git->retry_contended( "the lock on task $task_id", sub {
        my ( $oid, $current ) = $git->read_ref_with_oid($ref);

        my $broke = '';
        if ( defined $oid && length $current && $current ne $email ) {
            # Held by somebody else: a final answer, not contention. Say so
            # rather than dying, which is what the raw libgit2 lock error used
            # to do -- unless the lock has expired, in which case its holder is
            # gone and leaving it there would make the task unpickable forever.
            return ( 0, "locked by $current" ) unless $self->expired($oid);
            $broke = " (broke stale lock held by $current)";
        }

        # $oid undef => create-if-absent, the exclusive case. $oid set => this
        # is our own lock being refreshed, or a stale one being taken over;
        # either way the write is guarded against the ref not having moved since
        # the read above.
        return () unless $git->write_ref_cas( $ref, $email, $oid );
        return ( 1, "acquired$broke" );
    } );
}

# Whether the lock commit $oid points at is older than the TTL. Takes the OID
# rather than a task id so the age judged and the OID a takeover is guarded
# against are the same revision.
sub expired {
    my ( $self, $oid ) = @_;
    my $ttl = $self->ttl;
    return 0 unless $ttl && $ttl > 0;   # a zero/negative TTL disables expiry
    my $held_since = $self->git->commit_time($oid);
    # No readable timestamp is no evidence the holder is dead, and refusing to
    # steal is the safe direction -- `karr unlock` is still there.
    return 0 unless defined $held_since;
    return ( time - $held_since ) > $ttl ? 1 : 0;
}

# Every lock currently held on the board, with its holder, its age, and whether
# it has expired. Reported rather than acted on: seeing who holds what and for
# how long is the first half of getting out of a stuck board (#45).
sub locks {
    my ($self) = @_;
    my @locks;
    for my $ref ( $self->git->list_refs('refs/karr/tasks/') ) {
        next unless $ref =~ m{\Arefs/karr/tasks/(\d+)/lock\z};
        my $id = $1;
        my ( $oid, $owner ) = $self->git->read_ref_with_oid($ref);
        next unless defined $oid;
        my $held_since = $self->git->commit_time($oid);
        push @locks, {
            task_id    => 0 + $id,
            owner      => $owner,
            held_since => $held_since,
            age        => defined $held_since ? time - $held_since : undef,
            expired    => $self->expired($oid) ? 1 : 0,
        };
    }
    return sort { $a->{task_id} <=> $b->{task_id} } @locks;
}

# Drop a lock regardless of who holds it or how old it is. release() refuses to
# touch another agent's lock, which is right for the pick path and useless as an
# escape hatch -- the whole problem is that the holder is never coming back.
sub break_lock {
    my ( $self, $task_id ) = @_;
    $task_id //= $self->task_id;
    my $ref = $self->ref_name($task_id);
    return ( 0, "not locked" ) unless $self->git->ref_exists($ref);
    my $owner = $self->get($task_id);
    $self->git->delete_ref($ref);
    return ( 1, $owner );
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
