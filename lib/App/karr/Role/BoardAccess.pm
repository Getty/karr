# ABSTRACT: Role providing board discovery, sync lifecycle, and task access

package App::karr::Role::BoardAccess;
our $VERSION = '0.304';
use Moo::Role;

with 'App::karr::Role::BoardDiscovery';
with 'App::karr::Role::SyncLifecycle';

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

# Reject surplus positional arguments before a command does any work, matching
# kanban-md's cobra Args validators (ExactArgs/RangeArgs/MaximumNArgs) which
# refuse extra positionals ahead of RunE. The comma list stays the one and only
# batch syntax; there is no space-separated id batch.
#
# MooX::Cmd hands execute() the raw argv and echoes parsed option flags *and*
# their values back into it (e.g. `move 1 --next --claim tester` arrives as
# [1, --next, --claim, tester]). Positionals always precede options on the
# command line, so the positional count is the leading run of non-dash tokens;
# stopping at the first option flag ignores both the flags and their echoed
# values.
sub check_positional_args {
    my ($self, $args_ref, $max) = @_;

    my @positional;
    for my $arg (@$args_ref) {
        last if $arg =~ /^-/;
        push @positional, $arg;
    }
    return if @positional <= $max;

    my @extra   = @positional[$max .. $#positional];
    my %config  = $self->_options_config;
    my $usage   = $config{usage_string};

    die sprintf "unexpected extra argument%s: %s\n%s",
        (@extra == 1 ? '' : 's'),
        join(', ', map { "'$_'" } @extra),
        ($usage ? "$usage\n" : '');
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