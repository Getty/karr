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

# Extract the real positional arguments from the argv MooX::Cmd echoes back
# into execute(). Because MooX::Options runs with protect_argv (its default),
# the array handed to execute() still holds every original token in order:
# recognised option flags, the values they consumed, and --opt=value forms
# included (e.g. `move --claim tester 1 in-progress` arrives verbatim as
# [--claim, tester, 1, in-progress]). This gives cobra-style freedom to place
# flags before, between, or after positionals -- we just have to subtract the
# option tokens back out.
#
# We do that by walking the argv against the command's own %{_options_data}:
# a dash token is an option; if that option takes a value (has a 'format') and
# is given in space form (no inline '='), it also swallows the following token
# as its value -- even a flag-shaped value like `--append-body --weird`.
# Everything not eaten as an option or an option value is a positional, in
# order. Option-name matching mirrors how the token reaches us: leading dashes
# stripped, '-' folded to '_' to hit the underscore keys in _options_data, plus
# a reverse map of short aliases (e.g. -a => append_body, -t => timestamp).
# An unrecognised dash token is treated defensively as non-consuming: a genuine
# typo would already have been rejected upstream by MooX::Options, so the only
# accepted-but-unmatched shape here is a Getopt::Long abbreviation, and karr's
# abbreviatable flags (e.g. --jso for --json) consume nothing anyway.
sub positional_args {
    my ($self, $args_ref) = @_;

    my %options_data = $self->_options_data;
    my %by_name;
    for my $name (keys %options_data) {
        $by_name{$name} = $options_data{$name};
        my $short = $options_data{$name}{short};
        next unless defined $short;
        $by_name{$_} = $options_data{$name} for split /\|/, $short;
    }

    my @positional;
    my @args = @$args_ref;
    while (@args) {
        my $arg = shift @args;
        if ($arg =~ /^-/) {
            (my $name = $arg) =~ s/^-+//;        # drop leading dashes
            my $has_inline = $name =~ s/=.*//s;  # --opt=value carries its value
            $name =~ tr/-/_/;                    # match underscore keys
            my $data = $by_name{$name};
            shift @args if $data && $data->{format} && !$has_inline && @args;
            next;
        }
        push @positional, $arg;
    }
    return @positional;
}

# Reject surplus positional arguments before a command does any work, matching
# kanban-md's cobra Args validators (ExactArgs/RangeArgs/MaximumNArgs) which
# refuse extra positionals ahead of RunE. The comma list stays the one and only
# batch syntax; there is no space-separated id batch. Counting is done against
# positional_args (the real positionals with option tokens subtracted out), not
# a leading run of non-dash tokens, so `archive 1 --json 99` correctly rejects
# the trailing "99" instead of silently dropping it.
sub check_positional_args {
    my ($self, $args_ref, $max) = @_;

    my @positional = $self->positional_args($args_ref);
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