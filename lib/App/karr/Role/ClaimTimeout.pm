# ABSTRACT: Shared claim timeout logic

package App::karr::Role::ClaimTimeout;
our $VERSION = '0.402';
use Moo::Role;
use Time::Piece;

=head1 DESCRIPTION

Shared helper role for commands that need to interpret C<claim_timeout> values
and determine whether an existing claim should still block other agents.

=cut

sub _parse_timeout {
    my ($self, $timeout_str) = @_;
    return 3600 unless $timeout_str;
    if ($timeout_str =~ /^(\d+)h$/) { return $1 * 3600; }
    if ($timeout_str =~ /^(\d+)m$/) { return $1 * 60; }
    return 3600;
}

sub _claim_expired {
    my ($self, $task, $timeout_secs) = @_;
    return 0 unless $task->has_claimed_at;
    my $claimed = eval { Time::Piece->strptime($task->claimed_at =~ s/Z$//r, '%Y-%m-%dT%H:%M:%S') };
    return 0 unless $claimed;
    return (gmtime() - $claimed) > $timeout_secs;
}

1;
