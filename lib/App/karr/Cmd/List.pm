# ABSTRACT: List tasks with filtering and sorting

package App::karr::Cmd::List;
our $VERSION = '0.403';
use Moo;
use MooX::Cmd;
use MooX::Options (
  usage_string => 'USAGE: karr list [--status LIST] [--priority LIST] [--sort FIELD] [options]',
);
use App::karr::Role::BoardAccess;
use App::karr::Role::Output;
use App::karr::Task;
use App::karr::Config;
use App::karr::Error qw( user_error );

with 'App::karr::Role::BoardAccess', 'App::karr::Role::Output';

=head1 SYNOPSIS

    karr list
    karr list --status todo,in-progress --priority high,critical
    karr list --claimed-by agent-fox --compact
    karr list -s docker --json

=head1 DESCRIPTION

Lists tasks from the current board with optional filtering and sorting.
Archived tasks are excluded by default so the output focuses on active work.
Use C<--compact> for terse one-line output and C<--json> for machine-readable
automation.

=head1 FILTERS AND SORTING

=over 4

=item * C<--status>, C<--priority>

Accept comma-separated lists and only return tasks matching one of the
requested values.

=item * C<--assignee>, C<--tag>, C<--claimed-by>

Limit the result set to a specific assignee, tag, or claim owner.

=item * C<-s>, C<--search>

Performs a case-insensitive substring search across title, body, and tags.

=item * C<--sort>, C<--reverse>

Sort by C<id>, C<status>, C<priority>, C<created>, C<updated>, or C<due>, and
optionally reverse the result order. Any other field is a usage error (exit
C<2>).

C<status> and C<priority> follow the board config's own order, so C<--sort
priority> lists C<low> before C<critical> with the default C<priorities>
setting; reach for C<--reverse> to put the most urgent work first. Tasks
without a C<due> date sort last. Ties are broken by C<id>.

=back

=head1 SEE ALSO

L<karr>, L<App::karr>, L<App::karr::Cmd::Show>, L<App::karr::Cmd::Board>,
L<App::karr::Cmd::Create>, L<App::karr::Cmd::Pick>

=cut

option status => (
  is => 'ro',
  format => 's',
  doc => 'Filter by status (comma-separated)',
);

option priority => (
  is => 'ro',
  format => 's',
  doc => 'Filter by priority (comma-separated)',
);

option assignee => (
  is => 'ro',
  format => 's',
  doc => 'Filter by assignee',
);

option tag => (
  is => 'ro',
  format => 's',
  doc => 'Filter by tag',
);

option search => (
  is => 'ro',
  format => 's',
  short => 's',
  doc => 'Search tasks by title, body, or tags',
);

option claimed_by => (
  is => 'ro',
  format => 's',
  doc => 'Filter by claim owner',
);

# The complete set of --sort keys, in the order the usage message lists them.
# Single source for the option doc, the usage message, and _comparators.
my @SORT_FIELDS = qw( id status priority created updated due );

option sort => (
  is => 'ro',
  format => 's',
  default => sub { 'id' },
  doc => 'Sort by: ' . join(', ', @SORT_FIELDS),
);

option reverse => (
  is => 'ro',
  short => 'r',
  doc => 'Reverse sort order',
);

sub execute {
  my ($self, $args_ref, $chain_ref) = @_;
  my @tasks = $self->_load_tasks;
  @tasks = $self->_filter(\@tasks);
  @tasks = $self->_sort(\@tasks);

  if ($self->json) {
    $self->print_json([map { $_->to_frontmatter } @tasks]);
    return;
  }

  if ($self->compact) {
    for my $t (@tasks) {
      printf "#%-4u %10s %s\n", $t->id, $t->status, $t->title;
    }
    return;
  }

  printf "%-5s %10s %s\n", 'ID', 'STATUS', 'TITLE';
  printf "%s\n", '-' x 72;
  for my $t (@tasks) {
    my @meta;
    push @meta, $t->priority if defined $t->priority && length $t->priority;
    push @meta, '@' . $t->assignee if $t->has_assignee;
    push @meta, 'blocked' if $t->has_blocked;
    my $title = $t->title;
    $title .= ' [' . join(', ', @meta) . ']' if @meta;

    printf "#%-4u %10s %s\n",
      $t->id,
      $t->status,
      $title;
  }
  printf "\n%d task(s)\n", scalar @tasks;
}

sub _load_tasks {
  my ($self) = @_;
  return $self->load_tasks;
}

sub _filter {
  my ($self, $tasks) = @_;
  my @filtered = @$tasks;

  # Exclude terminal statuses (done/archived) by default, but let an explicit
  # --status request surface them.
  unless ($self->status) {
    @filtered = grep { !App::karr::Config->is_terminal_status($_->status) } @filtered;
  }

  if ($self->status) {
    my %statuses = map { $_ => 1 } split /,/, $self->status;
    @filtered = grep { $statuses{$_->status} } @filtered;
  }
  if ($self->priority) {
    my %priorities = map { $_ => 1 } split /,/, $self->priority;
    @filtered = grep { $priorities{$_->priority} } @filtered;
  }
  if ($self->assignee) {
    @filtered = grep { $_->has_assignee && $_->assignee eq $self->assignee } @filtered;
  }
  if ($self->tag) {
    @filtered = grep {
      my $t = $_;
      grep { $_ eq $self->tag } @{$t->tags};
    } @filtered;
  }
  if ($self->claimed_by) {
    @filtered = grep { $_->has_claimed_by && $_->claimed_by eq $self->claimed_by } @filtered;
  }
  if ($self->search) {
    my $q = lc($self->search);
    @filtered = grep {
      index(lc($_->title), $q) >= 0
      || index(lc($_->body), $q) >= 0
      || grep { index(lc($_), $q) >= 0 } @{$_->tags}
    } @filtered;
  }
  return @filtered;
}

sub _sort {
  my ($self, $tasks) = @_;
  my $field = $self->sort;

  # Look the key up in an explicit table; never call it as a method. The old
  # `$a->$field` turned a value straight from argv into a method call on
  # App::karr::Task, so `--sort slug` and `--sort to_markdown` both ran, and an
  # unknown key died with "Can't locate object method ... at List.pm line NNN".
  my $comparators = $self->_comparators;
  my $cmp = $comparators->{$field}
    or user_error( "Usage: karr list --sort ", join('|', @SORT_FIELDS),
                   " (got '$field')" );

  # Tie-break on id so the order is fully determined: Perl's sort is stable in
  # practice but not by contract, and load_tasks already hands tasks over in
  # ascending id order, so this pins what stability was silently providing.
  my @sorted = sort { $cmp->($a, $b) || $a->id <=> $b->id } @$tasks;
  @sorted = reverse @sorted if $self->reverse;
  return @sorted;
}

# One comparator per allowed --sort key. Status and priority follow the board
# config's own order rather than the alphabet or a hardcoded table, matching
# kanban-md's Sort/compareTasks (internal/board/sort.go) which indexes both
# through cfg.StatusIndex / cfg.PriorityIndex. A value that is not in the
# config gets index -1 and therefore sorts first, as kanban-md's IndexOf does.
sub _comparators {
  my ($self) = @_;
  my %status   = $self->_index_of( $self->config->statuses );
  my %priority = $self->_index_of( $self->config->priorities );
  return {
    id       => sub { $_[0]->id <=> $_[1]->id },
    status   => sub { ($status{$_[0]->status}     // -1) <=> ($status{$_[1]->status}     // -1) },
    priority => sub { ($priority{$_[0]->priority} // -1) <=> ($priority{$_[1]->priority} // -1) },
    # created/updated are ISO-8601 UTC stamps, so a string compare is
    # chronological.
    created  => sub { $_[0]->created cmp $_[1]->created },
    updated  => sub { $_[0]->updated cmp $_[1]->updated },
    due      => sub { $self->_cmp_due(@_) },
  };
}

sub _index_of {
  my ($self, @values) = @_;
  my %index;
  $index{$values[$_]} //= $_ for 0 .. $#values;
  return %index;
}

# `due` is optional. kanban-md's compareDue sorts a task without a due date
# last; the previous `('' cmp '')` fallback sorted it first.
sub _cmp_due {
  my ($self, $left, $right) = @_;
  my $l = $self->_due_of($left);
  my $r = $self->_due_of($right);
  return 0 unless defined $l || defined $r;
  return 1 unless defined $l;
  return -1 unless defined $r;
  return $l cmp $r;
}

sub _due_of {
  my ($self, $task) = @_;
  return undef unless $task->has_due;
  my $due = $task->due;
  return ( defined $due && length $due ) ? $due : undef;
}

1;
