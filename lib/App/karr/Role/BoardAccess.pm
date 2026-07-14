# ABSTRACT: Role providing board discovery, sync lifecycle, and task access

package App::karr::Role::BoardAccess;
our $VERSION = '0.402';
use Moo::Role;
use App::karr::Role::CliArgs;

with 'App::karr::Role::BoardDiscovery';
with 'App::karr::Role::SyncLifecycle';
with 'App::karr::Role::CliArgs';

=head1 DESCRIPTION

This role composes L<Role::BoardDiscovery> and L<Role::SyncLifecycle> and
adds task-access methods that delegate to the store. Commands compose this role
for full board functionality.

All task operations work directly against refs via C<< $self->store->load_tasks() >>
and similar. No temporary directory is created.

=cut

sub load_tasks {
    my ($self) = @_;
    return $self->store->load_tasks;
}

sub find_task {
    my ($self, $id) = @_;
    return $self->store->find_task($id);
}

sub save_task {
    my ($self, $task) = @_;
    return $self->store->save_task($task);
}

sub delete_task {
    my ($self, $id) = @_;
    return $self->store->delete_task($id);
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
    require App::karr::ActivityLog;
    return App::karr::ActivityLog->new(git => $git, role => $self->role);
}

sub append_log {
    my ($self, $git, %entry) = @_;
    return $self->activity_log($git)->log_entry(%entry);
}

sub save_config {
    my ($self, $effective) = @_;
    $effective //= $self->config;
    return $self->store->save_config($effective);
}

1;