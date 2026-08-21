# ABSTRACT: Change a task's status

package App::karr::Cmd::Move;
our $VERSION = '0.501';
use Moo;
use MooX::Cmd;
use MooX::Options (
  usage_string => 'USAGE: karr move ID[,ID,...] STATUS [--claim NAME] [--next|--prev]',
);
use App::karr::Role::BoardAccess;
use App::karr::Role::Output;
use App::karr::Role::TaskMutation;
use App::karr::Task;
use App::karr::Config;
use Time::Piece;
# Loaded without importing: this class composes no namespace::clean (MooX::Options
# forbids it), so an imported `JSON` would become a method on the command. The
# two booleans are wanted as functions anyway, the way App::karr::Task calls them.
use JSON::MaybeXS ();

with 'App::karr::Role::BoardAccess', 'App::karr::Role::Output',
     'App::karr::Role::TaskMutation';

=head1 SYNOPSIS

    karr move 7 done
    karr move 7 --next
    karr move 7,8,9 in-progress --claim agent-fox

=head1 DESCRIPTION

Moves one or more tasks to a new status. The command understands explicit
target statuses and relative movement via C<--next> or C<--prev>, and it
enforces C<require_claim> when the destination status requires an owner.

Moving a finished task back into a working column releases the claim the card
still carried, unless C<--claim> names the agent taking it up
(L<App::karr::Role::TaskMutation/apply_status_change>).

Moving a task to the status it already has changes nothing and therefore writes
nothing: the card keeps its C<updated> stamp, no activity-log entry is
appended, and the command reports C<Task N is already at STATUS> and exits 0 --
the answer C<karr archive> gives for an already-archived card, under the same
rule of the exit-code contract. C<--claim> is the exception: a claim handed to
the card is a change whether or not the status moves, so C<< karr move ID
STATUS --claim NAME >> takes a card whose claim ran out without needing a
detour through another column.

=head1 OPTIONS

=over 4

=item * C<--next>, C<--prev>

Advance or rewind relative to the status order defined in the board config.

=item * C<--claim>

Claim the task while moving it. This is commonly used for
C<in-progress> or C<review> states.

=back

=head1 JSON OUTPUT

Every result object carries C<changed>: true when the card moved, false when it
was already at the requested status. A reader that wants to tell the two apart
reads that field rather than comparing C<old_status> with C<new_status>, which
are both present in either case.

=head1 SEE ALSO

L<karr>, L<App::karr>, L<App::karr::Cmd::Show>, L<App::karr::Cmd::Edit>,
L<App::karr::Cmd::Pick>, L<App::karr::Cmd::Handoff>

=cut

option next => (
  is => 'ro',
  doc => 'Advance to next status',
);

option prev => (
  is => 'ro',
  doc => 'Move to previous status',
);

option claim => (
  is => 'ro',
  format => 's',
  doc => 'Claim task for an agent',
);

sub execute {
  my ($self, $args_ref, $chain_ref) = @_;

  $self->check_positional_args($args_ref, 2);

  $self->sync_before;
  $self->require_board;

  my @pos = $self->positional_args($args_ref);
  my $id_str = $pos[0] or die "Usage: karr move ID[,ID,...] [STATUS]\n";
  # `karr move , todo` passes the truthy "," above and then splits to an empty
  # list, so the loop below never ran: no ids, no output, no die, exit 0. A
  # command that silently did nothing is the one answer the exit-code contract
  # (ADR 0002) cannot express. The "Usage:" prefix is what bin/karr keys on to
  # make it a usage error (2) rather than a runtime failure (1).
  my @ids = $self->parse_ids($id_str);
  die "Usage: karr move ID[,ID,...] [STATUS]\n" unless @ids;
  my $new_status = $pos[1];

  my @statuses = $self->store->all_status_names;

  # Every id is attempted, whatever the ones before it did: a missing id used to
  # die from inside this loop and take the rest of the batch with it, so the
  # result depended on where the bad id sat in the list (ticket #61).
  my ($results, $failed) = $self->run_batch(\@ids, sub {
    my ($id) = @_;

    # Everything that reads the task happens inside the guard, --next/--prev
    # included: the target status is derived from the task's current status, so
    # deciding it outside the loop would decide it against a revision another
    # agent may already have replaced.
    my $old_status;
    my $unchanged;
    my $task = $self->update_task_guarded($id, sub {
      my ($task) = @_;

      $self->check_claim($task, $self->claim);

      my $task_new_status = $new_status;

      if ($self->next) {
        my $idx = $self->_status_index(\@statuses, $task->status);
        die "Already at last status\n" if $idx >= $#statuses;
        $task_new_status = $statuses[$idx + 1];
      } elsif ($self->prev) {
        my $idx = $self->_status_index(\@statuses, $task->status);
        die "Already at first status\n" if $idx <= 0;
        $task_new_status = $statuses[$idx - 1];
      }

      die "New status required\n" unless $task_new_status;

      # A move to the status the card already has, with no claim to hand over,
      # changes nothing -- so it writes nothing: the write is what stamps
      # `updated` and appends the activity-log entry, and both were saying a
      # move happened when none did (#231). Assigned on every attempt rather
      # than only in the branch where it is true: the callback re-runs on
      # contention, and this answer belongs to the revision that attempt read.
      #
      # --claim is what makes it not this case: `move ID <same status> --claim
      # NAME` writes claimed_by and a fresh claimed_at, which is how an agent
      # takes over a card whose claim ran out without moving it, and dropping
      # that silently would be this ticket's own bug pointing the other way.
      # kanban-md short-circuits in front of its claim handling and does drop
      # it; karr's claims expire and gate `pick`, so here the claim wins.
      #
      # After check_claim, not before it: whether somebody else's live claim
      # blocks this command is a question about the card, not about the work,
      # and kanban-md asks it in the same order.
      $unchanged = $task->status eq $task_new_status
        && !( defined $self->claim && length $self->claim );
      return $self->no_change if $unchanged;

      if ($self->claim) {
        $task->claimed_by($self->claim);
        $task->claimed_at(gmtime->datetime . 'Z');
      }

      $old_status = $self->apply_status_change($task, $task_new_status, $self->claim);
    });

    if ($unchanged) {
      # The wording `karr archive` already uses for the same answer, and ADR
      # 0002's exit 0: the card is where it was asked to be, which is success
      # and not a failure to report.
      printf "Task %d is already at %s: %s\n", $task->id, $task->status, $task->title
        unless $self->json;
      # `changed` is the field a --json reader keys on, and it is on both
      # answers rather than only on this one: a key that appears only when
      # nothing happened has to be tested for existence instead of for its
      # value, and tells a reader nothing at all on the karr that never wrote
      # it. old_status/new_status stay, holding the one status the card has, so
      # the shape of a move result does not change with its outcome.
      #
      # Neither report is called here. Nothing was written, so nothing stepped
      # over the expired claim this card may carry, and nothing took up work
      # that its dependencies could still be waiting on -- and
      # apply_status_change did not record either of them for this id.
      return { id => $task->id, title => $task->title, old_status => $task->status,
               new_status => $task->status, changed => JSON::MaybeXS::false() };
    }

    printf "Moved task %d: %s -> %s\n", $task->id, $old_status, $task->status unless $self->json;
    # After the write, not inside the guarded callback that decided it: see
    # App::karr::Role::DependencyCheck/dependency_report. Under --json the pair
    # it returns lands in this hash instead of on STDERR. Same for the expired
    # claim this move may have stepped over
    # (App::karr::Role::ClaimTimeout/expired_claim_report, #177), which is
    # reported first because it is about who held the card, not about the work.
    return { id => $task->id, title => $task->title, old_status => $old_status,
             new_status => $task->status, changed => JSON::MaybeXS::true(),
             $self->expired_claim_report( $task->id ),
             $self->dependency_report( $task->id ) };
  });

  $self->sync_after;

  $self->print_json_results(@$results);

  $self->report_batch_failure($failed, scalar @ids);
}

sub _status_index {
  my ($self, $statuses, $status) = @_;
  for my $i (0..$#$statuses) {
    return $i if $statuses->[$i] eq $status;
  }
  die "Unknown status: $status\n";
}

1;
