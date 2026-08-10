# ABSTRACT: Role providing board discovery, sync lifecycle, and task access

package App::karr::Role::BoardAccess;
our $VERSION = '0.500';
use Moo::Role;
use App::karr::Role::CliArgs;
use App::karr::ActivityLog;

with 'App::karr::Role::BoardDiscovery';
with 'App::karr::Role::SyncLifecycle';
with 'App::karr::Role::CliArgs';

=head1 DESCRIPTION

This role composes L<Role::BoardDiscovery> and L<Role::SyncLifecycle> and
adds task-access methods that delegate to the store. Commands compose this role
for full board functionality.

All task operations work directly against refs via C<< $self->store->load_tasks() >>
and similar. No temporary directory is created.

=head2 Activity logging

C<save_task> and C<delete_task> are the two doors a command changes a task
through, guarded writes included, so they are also where the activity log is
written. A command is recorded because it wrote, not because it remembered to
call C<append_log> -- before that, C<pick> was the only command that
remembered, and C<karr log> and C<karr show --me> ran on an almost empty log
(#64).

Every command write goes through one of the two, which is the point:
L<App::karr::Role::TaskMutation> and C<pick> hand their compare-and-swap
through C<save_task>'s optional expected-OID argument instead of reaching past
it to L<App::karr::BoardStore/save_task_cas>, so there is no second write path
to keep in step.

The action name comes from the command class (L</log_action>) and the actor
from its C<--claim>, the task's holder, or the Git identity (L</log_agent>).
Bulk paths that deliberately reinstate state verbatim -- C<import>, C<restore>,
C<repair> -- reach L<App::karr::BoardStore> directly and stay unlogged.

=cut

# Guards against logging one mutation twice within a single command run: pick
# saves the task (logged here) and then calls append_log itself.
has _logged_writes => (
    is      => 'ro',
    default => sub { {} },
);

sub load_tasks {
    my ($self) = @_;
    return $self->store->load_tasks;
}

sub find_task {
    my ($self, $id) = @_;
    return $self->store->find_task($id);
}

sub save_task {
    my ( $self, $task, $expected_oid ) = @_;
    # One door, guarded or not, so the activity log has exactly one place to
    # hang off. Handed the OID the card was read from (find_task_with_oid /
    # read_ref_with_oid) this is a compare-and-swap and returns false when
    # another agent got there first -- the caller re-reads and decides again,
    # and a write that never landed is never logged. Splitting the guarded path
    # off into its own method is what let move/edit/pick slip out of the log
    # once App::karr::Role::TaskMutation arrived (#64 again).
    my $wrote = @_ > 2
        ? $self->store->save_task_cas( $task, $expected_oid )
        : $self->store->save_task($task);
    return $wrote unless $wrote;
    $self->log_task_write( $task->id, $task->status, $task );
    return $wrote;
}

sub delete_task {
    my ($self, $id) = @_;
    my $result = $self->store->delete_task($id);
    $self->log_task_write($id);
    return $result;
}

sub allocate_next_id {
    my ($self) = @_;
    return $self->store->allocate_next_id;
}

sub parse_ids {
    my ($self, $id_str) = @_;
    return split /,/, $id_str;
}

sub activity_log {
    my ($self, $git) = @_;
    $git //= $self->git;
    return App::karr::ActivityLog->new(git => $git, role => $self->role);
}

sub append_log {
    my ($self, $git, %entry) = @_;
    my $key = ($entry{action} // '') . ':' . ($entry{task_id} // '');
    return 0 if $self->_logged_writes->{$key}++;
    return $self->activity_log($git)->log_entry(%entry);
}

=head2 log_action

The action name recorded for this command's writes: the class's own name
segment, hyphenated (C<App::karr::Cmd::AgentName> gives C<agent-name>). Naming
the action after the command is what lets a new mutating command be logged
without opting in.

=cut

sub log_action {
    my ($self) = @_;
    my $name = ref($self) || $self;
    $name =~ s/.*:://;
    $name =~ s/(?<=[a-z0-9])([A-Z])/-$1/g;
    return lc $name;
}

=head2 log_agent

Who a log entry is attributed to: this command's C<--claim> if it takes one,
else whoever holds the task, else the Git identity behind the board.

=cut

sub log_agent {
    my ($self, $task) = @_;
    if ($self->can('claim')) {
        my $claim = $self->claim;
        return $claim if defined $claim && length $claim;
    }
    return $task->claimed_by if $task && $task->has_claimed_by;
    my $git = $self->git;
    return $git->git_user_name || $git->git_user_email || 'unknown';
}

=head2 log_task_write

    $self->log_task_write( $task->id, $task->status, $task );

Records one task mutation in the activity log. Called by C<save_task> and
C<delete_task>; at most one entry per action and task id per command run.

=cut

sub log_task_write {
    my ($self, $task_id, $detail, $task) = @_;
    my $action = $self->log_action;
    return 0 if $self->_logged_writes->{"$action:$task_id"}++;
    return $self->activity_log->log_entry(
        agent   => $self->log_agent($task),
        action  => $action,
        task_id => $task_id + 0,
        ( defined $detail ? ( detail => $detail ) : () ),
    );
}

sub save_config {
    my ($self, $effective) = @_;
    $effective //= $self->config;
    return $self->store->save_config($effective);
}

1;