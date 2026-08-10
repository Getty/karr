# ABSTRACT: Hand off a task for review

package App::karr::Cmd::Handoff;
our $VERSION = '0.403';
use Moo;
use MooX::Cmd;
use MooX::Options (
  usage_string => 'USAGE: karr handoff ID --claim NAME [--note TEXT] [--block REASON] [--release]',
);
use App::karr::Role::BoardAccess;
use App::karr::Role::Output;
use App::karr::Task;
use App::karr::Config;
use Time::Piece;

with 'App::karr::Role::BoardAccess', 'App::karr::Role::Output', 'App::karr::Role::ClaimTimeout';

=head1 SYNOPSIS

    karr handoff 7 --claim agent-fox
    karr handoff 7 --claim agent-fox --note "Implementation complete" --timestamp
    karr handoff 7 --claim agent-fox --block "waiting for QA" --release

=head1 DESCRIPTION

Moves a task into C<review> and refreshes its claim so the next stage of work
can see who handed it off. The command can append a note, add a blocker, and
optionally release the claim after the handoff.

=head1 OPTIONS

=over 4

=item * C<--claim>

Required. Identifies the agent performing the handoff and is validated against
the current claim unless that claim has expired.

=item * C<--note>, C<--timestamp>

Append handoff text to the task body, optionally prefixed with the current UTC
timestamp.

=item * C<--block>, C<--release>

Record a blocking reason and/or clear the claim immediately after the handoff.

=back

=head1 SEE ALSO

L<karr>, L<App::karr>, L<App::karr::Cmd::Pick>, L<App::karr::Cmd::Move>,
L<App::karr::Cmd::Edit>, L<App::karr::Cmd::Log>

=cut

option claim => (
  is => 'ro',
  format => 's',
  required => 1,
  doc => 'Agent name claiming the task',
);

option note => (
  is => 'ro',
  format => 's',
  doc => 'Handoff note to append to body',
);

option timestamp => (
  is => 'ro',
  short => 't',
  doc => 'Prefix timestamp to note',
);

option block => (
  is => 'ro',
  format => 's',
  doc => 'Block task with reason',
);

option release => (
  is => 'ro',
  doc => 'Release claim after handoff',
);

sub execute {
  my ($self, $args_ref, $chain_ref) = @_;

  $self->check_positional_args($args_ref, 1);

  $self->sync_before;
  $self->require_board;

  my @pos = $self->positional_args($args_ref);
  my $id = $pos[0] or die "Usage: karr handoff ID --claim NAME [--note TEXT] [--block REASON] [--release]\n";

  my $task = $self->find_task($id);
  die "Task $id not found\n" unless $task;

  # The one claim-ownership rule, shared with move/edit/delete rather than
  # reimplemented here. Byte-identical message and behaviour to the copy this
  # replaces, and it picks up check_claim's RFC3339 stamp handling for free.
  $self->check_claim($task, $self->claim);

  # Move to review
  my $old_status = $task->status;
  if ($task->status ne 'review') {
    $task->status('review');
    $task->update_timestamps($old_status, 'review', ($self->store->all_status_names)[0]);
  }

  # Refresh claim
  $task->claimed_by($self->claim);
  $task->claimed_at(gmtime->datetime . 'Z');

  # Block if requested
  if ($self->block) {
    $task->block($self->block);
  }

  # Append note
  if ($self->note) {
    my $note_text = $self->note;
    if ($self->timestamp) {
      $note_text = gmtime->strftime('%Y-%m-%d %H:%M') . ' ' . $note_text;
    }
    my $have = defined $task->body && length $task->body;
    $task->body(($have ? $task->body . "\n" : '') . $note_text);
  }

  # Release claim if requested
  if ($self->release) {
    $task->clear_claimed_by;
    $task->clear_claimed_at;
  }

  $self->save_task($task);

  $self->sync_after;

  if ($self->json) {
    $self->print_json($task->to_json_hash);
    return;
  }

  my $msg = sprintf "Handed off task %d -> review", $task->id;
  $msg .= sprintf " (blocked: %s)", $self->block if $self->block;
  $msg .= " (claim released)" if $self->release;
  print "$msg\n";
}

1;
