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
use App::karr::Task;
use App::karr::Config;
use Time::Piece;

with 'App::karr::Role::BoardAccess', 'App::karr::Role::Output';

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
existing values.

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
  my @ids = $self->parse_ids($id_str);

  # Once, before touching any task: a batch edit must not leave half the ids
  # updated because the value was bad all along (ticket #54).
  my $config = App::karr::Config->from_merged( $self->store->effective_config );
  $config->validate_status( $self->status )     if defined $self->status;
  $config->validate_priority( $self->priority ) if defined $self->priority;
  App::karr::Config->validate_due( $self->due ) if defined $self->due;

  my @results;
  for my $id (@ids) {
    my $task = $self->find_task($id);
    die "Task $id not found\n" unless $task;

    $task->title($self->title)       if $self->title;
    $task->status($self->status)     if $self->status;
    $task->priority($self->priority) if $self->priority;
    $task->assignee($self->assignee) if $self->assignee;
    $task->due($self->due)           if $self->due;
    $task->body($self->body)         if defined $self->body;

    if ($self->append_body) {
      # length, not truth: appending to a body of "0" must not replace it
      # (ticket #78).
      my $have = defined $task->body && length $task->body;
      $task->body(($have ? $task->body . "\n" : '') . $self->append_body);
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
      $task->block($self->block);
    }

    if ($self->unblock) {
      $task->unblock;
    }

    $self->save_task($task);

    push @results, { id => $task->id, title => $task->title };
    printf "Updated task %d: %s\n", $task->id, $task->title unless $self->json;
  }

  $self->sync_after;

  $self->print_json_results(@results);
}

1;
