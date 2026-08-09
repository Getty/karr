# ABSTRACT: Shared claim timeout logic

package App::karr::Role::ClaimTimeout;
our $VERSION = '0.403';
use Moo::Role;
use Time::Piece;

=head1 DESCRIPTION

Shared helper role for commands that need to interpret C<claim_timeout> values
and determine whether an existing claim should still block other agents.

C<check_claim> is the one claim-ownership rule in karr. Every command that
mutates an existing task has to apply it, and has to apply it against the same
revision of the task it then writes -- see
L<App::karr::Role::TaskMutation/update_task_guarded>.

=cut

sub _parse_timeout {
    my ($self, $timeout_str) = @_;
    return 3600 unless $timeout_str;
    if ($timeout_str =~ /^(\d+)h$/) { return $1 * 3600; }
    if ($timeout_str =~ /^(\d+)m$/) { return $1 * 60; }
    return 3600;
}

# The board's configured claim timeout in seconds, so callers do not each have
# to remember the '1h' fallback.
sub claim_timeout_secs {
    my ($self) = @_;
    return $self->_parse_timeout( $self->store->effective_config->{claim_timeout} // '1h' );
}

# karr and kanban-md both stamp claims with RFC3339, but not the same RFC3339.
# karr writes `gmtime->datetime . 'Z'` -- no fraction, always UTC. kanban-md
# writes Go's time.RFC3339Nano off the agent's local clock, verified against the
# real binary as 2026-08-09T17:28:46.449764553+02:00.
#
# The old parse stripped a trailing "Z" and handed the rest to a bare
# '%Y-%m-%dT%H:%M:%S', so the fraction and the offset were thrown away and the
# stamp was read as if it were UTC. A claim stamped +02:00 looked two hours
# younger than it was and never expired; one stamped -05:00 looked five hours
# older and was stolen while its owner was still working. Time::Piece also
# warned "Garbage at end of string in strptime" to STDERR on every single call,
# which meant every `karr pick` next to a kanban-md agent (ticket #57).
#
# So match the whole grammar instead: drop only the fractional seconds --
# sub-second precision cannot matter against a timeout measured in minutes --
# and hand the offset to strptime's %z, which is what actually normalises to
# UTC. Time::Piece's %z wants +hhmm rather than RFC3339's +hh:mm, and does not
# know "Z" at all, so both are normalised first. A stamp with no offset is read
# as UTC, which is what karr's own writer means by it.
#
# Because the format now matches the whole string, strptime has nothing left
# over to complain about and the STDERR noise goes away with it. A stamp that
# does not match at all returns undef and is treated as "not expired", the same
# conservative answer as before: never expiring is a stuck claim, wrongly
# expiring is a stolen one.
sub _parse_claim_stamp {
    my ($self, $stamp) = @_;
    return undef unless defined $stamp;
    my ($civil, $offset) = $stamp =~ m{
        \A (\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})   # civil date and time
           (?: \. \d+ )?                           # fractional seconds, dropped
           ( Z | [+-]\d{2}:?\d{2} )?               # UTC offset, or none
        \z
    }x or return undef;
    $offset = '+0000' if !defined $offset || uc($offset) eq 'Z';
    $offset =~ s/://;
    my $parsed = eval { Time::Piece->strptime( "$civil$offset", '%Y-%m-%dT%H:%M:%S%z' ) };
    return $parsed;
}

sub _claim_expired {
    my ($self, $task, $timeout_secs) = @_;
    return 0 unless $task->has_claimed_at;
    my $claimed = $self->_parse_claim_stamp( $task->claimed_at );
    return 0 unless defined $claimed;
    return (gmtime() - $claimed) > $timeout_secs;
}

# The one claim-ownership rule, mirroring kanban-md's task.CheckClaim
# (internal/task/validate.go): an unclaimed task is free, the current claimant
# may always proceed, and an expired claim no longer blocks anybody. Anything
# else belongs to an agent who is still working on it, and the mutation is
# refused rather than silently taking the claim over (ticket #56).
#
# Two deliberate differences from kanban-md:
#
#   * an expired claim is not cleared here. kanban-md's CheckClaim blanks
#     ClaimedBy as a side effect of asking the question; in karr that would
#     change what the require_claim check in
#     L<App::karr::Role::TaskMutation/apply_status_change> sees a few lines
#     later, turning an allowed move into a refused one. Expired claims are
#     reaped where they always were, by `karr pick`.
#
#   * the message stays "Task N is claimed by X", the wording `karr handoff`
#     has always used, rather than kanban-md's "add --claim X" hint: `karr
#     delete` has no --claim option, so that hint would be unfollowable for one
#     of the four callers.
sub check_claim {
    my ($self, $task, $claimant) = @_;
    return 1 unless $task->has_claimed_by && length $task->claimed_by;
    return 1 if defined $claimant && length $claimant && $task->claimed_by eq $claimant;
    return 1 if $self->_claim_expired( $task, $self->claim_timeout_secs );
    die sprintf "Task %d is claimed by %s\n", $task->id, $task->claimed_by;
}

1;
