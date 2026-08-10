# ABSTRACT: Atomically find and claim the next available task

package App::karr::Cmd::Pick;
our $VERSION = '0.403';
use Moo;
use MooX::Cmd;
use MooX::Options (
  usage_string => 'USAGE: karr pick --claim NAME [--move STATUS] [--status LIST] [--tags LIST]',
);
use App::karr::Role::BoardAccess;
use App::karr::Role::Output;
use App::karr::Task;
use App::karr::Config;
use App::karr::Lock;
use Time::Piece;

with 'App::karr::Role::BoardAccess', 'App::karr::Role::Output', 'App::karr::Role::ClaimTimeout';

=head1 SYNOPSIS

    karr pick --claim agent-fox
    karr pick --claim agent-fox --status todo --move in-progress
    karr pick --claim agent-fox --tags backend,urgent --json

=head1 DESCRIPTION

Selects the next available task for an agent, taking class of service,
priority, blocked state, and claim expiry into account. When the board lives in
a Git repository, the command also uses lock refs so concurrent agents do not
pile onto the same candidate.

=head1 SELECTION RULES

=over 4

=item * Eligible statuses

If C<--status> is omitted, tasks in C<done> and C<archived> are excluded.

=item * Claim timeout

Already claimed tasks are ignored unless their claim timestamp has expired
according to C<claim_timeout>.

=item * Ordering

Candidates are sorted by class of service, then by priority, then by task id.

=item * C<--move>

Optionally updates the picked task to a new status such as C<in-progress>.

=back

=head1 EXCLUSIVITY

The board is read once to rank candidates, but nothing is decided on that
reading. Every candidate is re-read from its ref after its lock is taken, tested
against the same predicate a second time, and written back under a
compare-and-swap on the OID it was just read from. An agent that loses that
swap has picked nothing and moves to the next candidate.

That belt-and-braces shape is not defensive programming, it is the fix for #86.
The lock ref alone cannot make a pick exclusive: its holder identity is the
clone's C<user.email>, which every agent on one machine shares, so twelve
parallel picks each acquired the lock quite legitimately, each acted on a
snapshot taken before any lock existed, and each wrote its claim over the
previous one -- nine agents were told they owned task 1, and the card named only
the last of them. The lock now only keeps agents off each other's candidates;
the compare-and-swap is what binds the claim.

=head1 LOCK EXPIRY

The lock is taken, used, and released within one command, and (since #45) it is
released before the push rather than after it, so it is never published to the
remote on the success path.

An agent that dies in between still leaves one behind, so locks expire: the
board's C<lock_timeout> (default C<5m>) is how long one may be held before
another agent takes it over. It is deliberately a separate knob from
C<claim_timeout> (default C<1h>) -- a claim covers a work session, a lock covers
the few milliseconds this command spends writing one card, and reusing the claim
window would leave a crashed agent's task unpickable for an hour.
L<App::karr::Cmd::Unlock> is the manual escape hatch.

=head1 SEE ALSO

L<karr>, L<App::karr>, L<App::karr::Cmd::List>, L<App::karr::Cmd::Move>,
L<App::karr::Cmd::Handoff>, L<App::karr::Cmd::AgentName>,
L<App::karr::Cmd::Unlock>

=cut

option claim => (
  is => 'ro',
  format => 's',
  required => 1,
  doc => 'Agent name to claim the task for',
);

option status => (
  is => 'ro',
  format => 's',
  doc => 'Source status(es) to pick from (comma-separated)',
);

option move => (
  is => 'ro',
  format => 's',
  doc => 'Move picked task to this status',
);

option tags => (
  is => 'ro',
  format => 's',
  doc => 'Only pick tasks matching at least one tag',
);

sub execute {
  my ($self, $args_ref, $chain_ref) = @_;

  $self->sync_before;
  $self->require_board;

  my $ec = $self->store->effective_config;
  my $timeout = $self->_parse_timeout($ec->{claim_timeout} // '1h');

  # A ranking, not a decision. Every one of these is re-read and re-tested under
  # its own lock before anything is written (see EXCLUSIVITY above).
  my @tasks = grep { $self->_is_pickable($_, $timeout) } $self->load_tasks;

  # Sort by class priority, then by priority
  my %class_order = App::karr::Config->class_order;
  my %pri_order   = App::karr::Config->priority_order;

  @tasks = sort {
    ($class_order{$a->class} // 2) <=> ($class_order{$b->class} // 2)
    || ($pri_order{$a->priority} // 2) <=> ($pri_order{$b->priority} // 2)
    || $a->id <=> $b->id
  } @tasks;

  unless (@tasks) {
    print "No available tasks to pick.\n";
    return;
  }

  # Try to lock + claim. A karr board lives in refs/karr/*, which exist only
  # inside a Git repo, so reaching this point means we are in one -- the
  # locking path is unconditional.
  my $lock = App::karr::Lock->new(
    git => $self->git,
    # Not the 1h _parse_timeout falls back to on its own: see LOCK EXPIRY.
    ttl => $self->_parse_timeout($ec->{lock_timeout}, App::karr::Lock->DEFAULT_TTL),
  );
  my $email = $self->git->git_user_email || $self->claim;

  my $picked;
  for my $candidate (@tasks) {
    my ($ok) = $lock->acquire($candidate->id, $email);
    next unless $ok;

    # Hold the lock for the claim and nothing else, and give it back on the way
    # out either way. Before #45 a die in here left the ref behind for good.
    $picked = eval { $self->_claim_under_lock($candidate->id, $timeout) };
    my $err = $@;
    $lock->release($candidate->id, $email);
    die $err if $err;

    last if $picked;
  }

  unless ($picked) {
    print "No available tasks to pick (every candidate was locked or taken).\n";
    return;
  }

  # Both writes have to happen before the push, or they never leave this clone:
  # sync_after is the last thing that talks to the remote and it disarms the
  # SyncGuard behind it. The lock release above is the same story -- publishing
  # a lock and then deleting it locally left the ref on the remote forever (#45).
  $self->append_log($self->git,
    agent   => $self->claim,
    action  => 'pick',
    task_id => $picked->id,
    detail  => $picked->status,
  );

  $self->sync_after;

  if ($self->json) {
    $self->print_json($picked->to_json_hash);
    return;
  }

  printf "Picked task %d: %s (claimed by %s)\n", $picked->id, $picked->title, $self->claim;
  printf "Status: %s | Priority: %s | Class: %s\n", $picked->status, $picked->priority, $picked->class;
  if ($picked->body) {
    print "\n" . $picked->body . "\n";
  }
}

# The one and only definition of "this card is available to me right now". It is
# a method rather than a chain of greps in execute so that the pre-lock ranking
# and the re-read under the lock cannot drift apart: the second test has to be
# the same test, or moving it inside the lock buys nothing (#86).
sub _is_pickable {
  my ($self, $task, $timeout) = @_;
  return 0 unless $task;

  if ($self->status) {
    my %allowed = map { $_ => 1 } split /,/, $self->status;
    return 0 unless $allowed{$task->status};
  } else {
    return 0 if App::karr::Config->is_terminal_status($task->status);
  }

  return 0 if $task->has_claimed_by && !$self->_claim_expired($task, $timeout);
  return 0 if $task->has_blocked;

  if ($self->tags) {
    my %wanted = map { $_ => 1 } split /,/, $self->tags;
    return 0 unless grep { $wanted{$_} } @{$task->tags};
  }

  return 1;
}

# Claim one candidate, or return false if it is no longer ours to claim.
#
# Everything here reads the card fresh: the ranking in execute was built from a
# snapshot taken before any lock existed and is stale by the time we get here.
# The write is guarded against the OID that same read came from, so losing to
# another agent is a false return rather than a silent overwrite. retry_contended
# separates the two ways a compare-and-swap can fail: the card changed under us
# (re-read, decide again) versus the card is taken (final, move on).
sub _claim_under_lock {
  my ($self, $id, $timeout) = @_;

  return $self->git->retry_contended("the claim on task $id", sub {
    my ($oid, $task) = $self->store->find_task_with_oid($id);
    return (0) unless $self->_is_pickable($task, $timeout);

    $task->claimed_by($self->claim);
    $task->claimed_at(gmtime->datetime . 'Z');

    if ($self->move) {
      $task->status($self->move);
      if ($self->move eq 'in-progress' && !$task->has_started) {
        $task->started(gmtime->strftime('%Y-%m-%d'));
      }
    }

    return () unless $self->save_task($task, $oid);
    return $task;
  });
}

1;
