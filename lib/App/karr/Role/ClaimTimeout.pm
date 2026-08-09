# ABSTRACT: Shared claim timeout logic

package App::karr::Role::ClaimTimeout;
our $VERSION = '0.403';
use Moo::Role;
use Time::Piece;
use App::karr::Config;

=head1 DESCRIPTION

Shared helper role for commands that need to interpret C<claim_timeout> values
and determine whether an existing claim should still block other agents.

=cut

# The whole Go duration grammar, not just ^\d+[hm]$: kanban-md writes
# claim_timeout with time.ParseDuration, so an imported `1h30m` has to mean
# ninety minutes here too instead of silently collapsing to the 1h fallback
# (ticket #78). Anything unparseable -- including "7d", which Go rejects as well
# -- still falls back to an hour rather than to zero, which would make every
# claim instantly stealable.
sub _parse_timeout {
    my ($self, $timeout_str) = @_;
    return 3600 unless $timeout_str;
    my $secs = App::karr::Config->parse_duration($timeout_str);
    return 3600 unless defined $secs && $secs > 0;
    return $secs;
}

sub _claim_expired {
    my ($self, $task, $timeout_secs) = @_;
    return 0 unless $task->has_claimed_at;
    my $claimed = eval { Time::Piece->strptime($task->claimed_at =~ s/Z$//r, '%Y-%m-%dT%H:%M:%S') };
    return 0 unless $claimed;
    return (gmtime() - $claimed) > $timeout_secs;
}

1;
