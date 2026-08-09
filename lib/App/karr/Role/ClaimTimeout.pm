# ABSTRACT: Shared claim timeout logic

package App::karr::Role::ClaimTimeout;
our $VERSION = '0.403';
use Moo::Role;
use Time::Piece;

=head1 DESCRIPTION

Shared helper role for commands that need to interpret C<claim_timeout> values
and determine whether an existing claim should still block other agents.

=cut

# $fallback is what an absent or unparseable value means. It defaults to an
# hour, which is right for claim_timeout but far too long for lock_timeout --
# a lock covers one pick transaction, not a work session, so App::karr::Cmd::Pick
# passes its own (see LOCK_TIMEOUT_FALLBACK there).
sub _parse_timeout {
    my ($self, $timeout_str, $fallback) = @_;
    $fallback //= 3600;
    return $fallback unless $timeout_str;
    if ($timeout_str =~ /^(\d+)h$/) { return $1 * 3600; }
    if ($timeout_str =~ /^(\d+)m$/) { return $1 * 60; }
    if ($timeout_str =~ /^(\d+)s$/) { return $1; }
    return $fallback;
}

sub _claim_expired {
    my ($self, $task, $timeout_secs) = @_;
    return 0 unless $task->has_claimed_at;
    my $claimed = eval { Time::Piece->strptime($task->claimed_at =~ s/Z$//r, '%Y-%m-%dT%H:%M:%S') };
    return 0 unless $claimed;
    return (gmtime() - $claimed) > $timeout_secs;
}

1;
