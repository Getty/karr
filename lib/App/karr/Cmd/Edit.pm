# ABSTRACT: Modify an existing task

package App::karr::Cmd::Edit;
our $VERSION = '0.403';
use Moo;
use MooX::Cmd;
use MooX::Options (
  usage_string => 'USAGE: karr edit ID[,ID,...] [--title TEXT] [--priority LEVEL] [options]',
);
use App::karr::Role::BoardAccess;
use App::karr::Role::Output;
use App::karr::Role::TaskMutation;
use App::karr::Task;
use Time::Piece;

with 'App::karr::Role::BoardAccess', 'App::karr::Role::Output',
     'App::karr::Role::TaskMutation';

=head1 SYNOPSIS

    karr edit 5 --title "Updated title"
    karr edit 5 --add-tag urgent --remove-tag stale
    karr edit 5 -a "Waiting for review"
    karr edit 5 --claim agent-fox --block "waiting on API"

=head1 DESCRIPTION

Updates one or more existing tasks in place. Use it to adjust metadata, append
notes, manage tags, claim or release ownership, and mark tasks as blocked or
unblocked without changing the task id.

=head1 COMMON OPERATIONS

=over 4

=item * Metadata updates

C<--title>, C<--status>, C<--priority>, C<--assignee>, and C<--due> replace
existing values. C<--status> is the same status change L<App::karr::Cmd::Move>
performs and obeys the same rules, C<require_claim> included.

=item * Claim ownership

Editing a task claimed by another agent is refused unless that claim has
expired. C<--claim> with the current claimant's name proceeds, and C<--release>
is exempt, since breaking a stale claim is what it is for.

=item * Body updates

C<--body> replaces the entire body; C<-a>/C<--append-body> appends a new line
to the existing body text.

=item * Claims and blocking

C<--claim> refreshes claim ownership and timestamp, C<--release> clears the
claim, C<--block> records a blocking reason, and C<--unblock> removes it.

=item * Tag management

C<--add-tag> and C<--remove-tag> accept comma-separated lists.

=back

=head1 SEE ALSO

L<karr>, L<App::karr>, L<App::karr::Cmd::Show>, L<App::karr::Cmd::Move>,
L<App::karr::Cmd::Handoff>, L<App::karr::Cmd::List>

=cut

option title => (
  is => 'ro',
  format => 's',
  doc => 'New title',
);

option status => (
  is => 'ro',
  format => 's',
  doc => 'New status',
);

option priority => (
  is => 'ro',
  format => 's',
  doc => 'New priority',
);

option assignee => (
  is => 'ro',
  format => 's',
  doc => 'New assignee',
);

option add_tag => (
  is => 'ro',
  format => 's',
  doc => 'Add tags (comma-separated)',
);

option remove_tag => (
  is => 'ro',
  format => 's',
  doc => 'Remove tags (comma-separated)',
);

option due => (
  is => 'ro',
  format => 's',
  doc => 'New due date',
);

option body => (
  is => 'ro',
  format => 's',
  doc => 'New body text',
);

option append_body => (
  is => 'ro',
  format => 's',
  short => 'a',
  doc => 'Append text to body',
);

option claim => (
  is => 'ro',
  format => 's',
  doc => 'Claim task for an agent',
);

option release => (
  is => 'ro',
  doc => 'Release claim',
);

option block => (
  is => 'ro',
  format => 's',
  doc => 'Mark as blocked with reason',
);

option unblock => (
  is => 'ro',
  doc => 'Clear blocked state',
);

sub execute {
  my ($self, $args_ref, $chain_ref) = @_;

  $self->check_positional_args($args_ref, 1);

  $self->sync_before;

  my @pos = $self->positional_args($args_ref);
  my $id_str = $pos[0] or die "Usage: karr edit ID[,ID,...] [FLAGS]\n";
  # See the note in Cmd::Move: a comma with no ids around it is truthy here and
  # splits to nothing, so the command used to exit 0 having done nothing.
  my @ids = $self->parse_ids($id_str);
  die "Usage: karr edit ID[,ID,...] [FLAGS]\n" unless @ids;

  my @results;
  for my $id (@ids) {
    my $task = $self->update_task_guarded($id, sub {
      my ($task) = @_;

      # --release is the one edit that may act on somebody else's claim: it
      # exists precisely to break a claim a crashed agent left behind, and it
      # is karr's only way out of one before the timeout. Everything else has
      # to own the claim, or find it expired. Same carve-out as kanban-md's
      # validateEditClaim (cmd/edit.go).
      $self->check_claim($task, $self->claim) unless $self->release;

      $task->title($self->title)       if $self->title;
      $self->apply_status_change($task, $self->status, $self->claim) if $self->status;
      $task->priority($self->priority) if $self->priority;
      $task->assignee($self->assignee) if $self->assignee;
      $task->due($self->due)           if $self->due;
      $task->body($self->body)         if defined $self->body;

      if ($self->append_body) {
        $task->body(($task->body ? $task->body . "\n" : '') . $self->append_body);
      }

      if ($self->add_tag) {
        my @new = split /,/, $self->add_tag;
        my %existing = map { $_ => 1 } @{$task->tags};
        push @{$task->tags}, grep { !$existing{$_} } @new;
      }

      if ($self->remove_tag) {
        my %remove = map { $_ => 1 } split /,/, $self->remove_tag;
        $task->tags([grep { !$remove{$_} } @{$task->tags}]);
      }

      if ($self->claim) {
        $task->claimed_by($self->claim);
        $task->claimed_at(gmtime->datetime . 'Z');
      }

      if ($self->release) {
        $task->clear_claimed_by;
        $task->clear_claimed_at;
      }

      if ($self->block) {
        $task->blocked($self->block);
      }

      if ($self->unblock) {
        $task->clear_blocked;
      }
    });

    push @results, { id => $task->id, title => $task->title };
    printf "Updated task %d: %s\n", $task->id, $task->title unless $self->json;
  }

  $self->sync_after;

  $self->print_json_results(@results);
}

1;
