# ABSTRACT: Generate board context summary for embedding

package App::karr::Cmd::Context;
our $VERSION = '0.403';
use Moo;
use MooX::Cmd;
use MooX::Options (
  usage_string => 'USAGE: karr context [--write-to FILE] [--sections LIST] [--days N] [--json]',
);
use Path::Tiny ();
use Time::Piece;
use App::karr::Role::BoardAccess;
use App::karr::Role::Output;
use App::karr::Task;
use App::karr::Config;

with 'App::karr::Role::BoardAccess', 'App::karr::Role::Output';

=head1 SYNOPSIS

    karr context
    karr context --sections blocked,overdue
    karr context --write-to AGENTS.md --days 14
    karr context --json

=head1 DESCRIPTION

Builds a concise board summary suitable for embedding into agent context files
such as F<AGENTS.md>. The command can print Markdown directly, emit structured
JSON, or update an existing file between sentinel comments.

=head1 SECTIONS

The generated context can include C<in-progress>, C<blocked>, C<overdue>, and
C<recently-completed>. Use C<--sections> with a comma-separated list to limit
the output to a subset.

=head1 FILE UPDATE MODE

When C<--write-to> is used, the command replaces the content between
C<BEGIN kanban-md context> and C<END kanban-md context> if those sentinels are
already present; otherwise it appends the generated block to the file.

=head1 SEE ALSO

L<karr>, L<App::karr>, L<App::karr::Cmd::Board>, L<App::karr::Cmd::List>,
L<App::karr::Cmd::Config>, L<App::karr::Cmd::Skill>

=cut

option write_to => (
  is => 'ro',
  format => 's',
  doc => 'Write context to file (create or update)',
);

option sections => (
  is => 'ro',
  format => 's',
  doc => 'Comma-separated section filter (in-progress,blocked,overdue,recently-completed)',
);

option days => (
  is => 'ro',
  format => 'i',
  default => sub { 7 },
  doc => 'Lookback days for recently-completed (default: 7)',
);

sub execute {
  my ($self, $args_ref, $chain_ref) = @_;

  my $ec = $self->store->effective_config;
  my @tasks = $self->load_tasks;
  my @statuses = $self->store->all_status_names;

  # Determine terminal and first statuses
  my $first_status = $statuses[0];

  # Exclude archived from all operations
  my @active_tasks = grep { !$self->store->is_terminal_status($_->status) } @tasks;

  # Build summary
  my $board_name = $ec->{board}{name} // 'Kanban Board';
  my $total = scalar @active_tasks;
  my $active = grep { $_->status ne $first_status && !$self->store->is_terminal_status($_->status) } @active_tasks;
  my $blocked = grep { $_->has_blocked } @active_tasks;
  my $overdue = $self->_count_overdue(\@active_tasks);

  # Build sections
  my %wanted_sections;
  if ($self->sections) {
    %wanted_sections = map { $_ => 1 } split /,/, $self->sections;
  }

  my @section_data;
  my @all_sections = qw(in-progress blocked overdue recently-completed);

  for my $sec (@all_sections) {
    next if $self->sections && !$wanted_sections{$sec};
    my @items;

    if ($sec eq 'in-progress') {
      @items = map { $self->_task_item($_) }
        sort { $self->_pri_order($a) <=> $self->_pri_order($b) }
        grep { $_->status ne $first_status && !$self->store->is_terminal_status($_->status) && !$_->has_blocked }
        @active_tasks;
    } elsif ($sec eq 'blocked') {
      @items = map { $self->_task_item($_, 'blocked: ' . ($_->has_block_reason ? $_->block_reason : '')) }
        grep { $_->has_blocked }
        @active_tasks;
    } elsif ($sec eq 'overdue') {
      my $now = gmtime->strftime('%Y-%m-%d');
      @items = map { $self->_task_item($_, 'due ' . $_->due) }
        grep { $self->_is_overdue($_, $now) }
        @active_tasks;
    } elsif ($sec eq 'recently-completed') {
      # Over every task, not @active_tasks: that list is by definition the
      # non-terminal ones, so intersecting it with the terminal statuses was
      # empty by construction and this section had never once had an entry on
      # any board (ticket #99). kanban-md's buildRecentlyCompletedSection scans
      # the whole task list too.
      #
      # "Recently" is bounded by the completion stamp, as it is there, but to
      # the day rather than to the second: `completed` is a string here and an
      # interop card can carry it as a bare `YYYY-MM-DD`, as an RFC3339 stamp
      # in UTC, or as one with a local offset, and a day-granular cutoff is the
      # coarsest bound all three compare correctly against.
      my $cutoff = (gmtime() - ($self->days * 86400))->strftime('%Y-%m-%d');
      @items = map { $self->_task_item($_, 'completed ' . ($_->completed // '')) }
        sort { ($b->completed // '') cmp ($a->completed // '') }
        grep { $self->store->is_terminal_status($_->status) && $_->status ne 'archived' && $_->has_completed && $_->completed ge $cutoff }
        @tasks;
    }

    push @section_data, { name => $sec, items => \@items } if @items;
  }

  if ($self->json) {
    my $out = {
      board_name => $board_name,
      summary => {
        total_tasks => $total,
        active => $active,
        blocked => $blocked,
        overdue => $overdue,
      },
      sections => \@section_data,
    };
    $self->print_json($out);
    return;
  }

  # Render markdown
  my $md = $self->_render_markdown($board_name, $total, $active, $blocked, $overdue, \@section_data);

  if ($self->write_to) {
    $self->_write_to_file($md);
  } else {
    print $md;
  }
}

sub _render_markdown {
  my ($self, $board_name, $total, $active, $blocked, $overdue, $sections) = @_;
  # The "kanban-md" spelling in these BEGIN/END markers (and the matching
  # regex in _write_to_file below) is an intentional interop contract: karr
  # and kanban-md maintain the same context block inside a shared host file
  # (e.g. AGENTS.md) by matching identical sentinels, so switching tools
  # updates the same block and leaves no orphaned markers. Do NOT rename to
  # "karr".
  my $md = "<!-- BEGIN kanban-md context -->\n";
  $md .= "## Board: $board_name\n\n";
  $md .= "**$total tasks** | $active active | $blocked blocked | $overdue overdue\n\n";

  my %section_title = (
    'in-progress'        => 'In Progress',
    'blocked'            => 'Blocked',
    'overdue'            => 'Overdue',
    'recently-completed' => 'Recently Completed',
  );

  for my $sec (@$sections) {
    $md .= "### " . ($section_title{$sec->{name}} // $sec->{name}) . "\n\n";
    for my $item (@{$sec->{items}}) {
      $md .= sprintf "- **#%d** %s (%s", $item->{id}, $item->{title}, $item->{priority};
      $md .= ", \@$item->{assignee}" if $item->{assignee};
      $md .= ")";
      $md .= " — $item->{note}" if $item->{note};
      $md .= "\n";
    }
    $md .= "\n";
  }

  $md .= "<!-- END kanban-md context -->\n";
  return $md;
}

sub _write_to_file {
  my ($self, $md) = @_;
  my $file = Path::Tiny::path($self->write_to);

  if ($file->exists) {
    my $content = $file->slurp_utf8;
    if ($content =~ /<!-- BEGIN kanban-md context -->.*<!-- END kanban-md context -->/s) {
      $content =~ s/<!-- BEGIN kanban-md context -->.*<!-- END kanban-md context -->\n?/$md/s;
      $file->spew_utf8($content);
    } else {
      my $sep = $content =~ /\n$/ ? "\n" : "\n\n";
      $file->spew_utf8($content . $sep . $md);
    }
  } else {
    $file->spew_utf8($md);
  }

  printf "Context written to %s\n", $self->write_to;
}

sub _task_item {
  my ($self, $task, $note) = @_;
  return {
    id       => $task->id,
    title    => $task->title,
    status   => $task->status,
    priority => $task->priority,
    # Empty means absent, as in pick and list (ticket #59): an `assignee: ""`
    # from kanban-md must not become an "assignee":"" key in the --json
    # payload. The Markdown renderer already tested truth rather than the
    # predicate, so only --json ever saw it.
    ( $task->has_assignee && length $task->assignee
      ? ( assignee => $task->assignee )
      : () ),
    ($note ? (note => $note) : ()),
  };
}

sub _pri_order {
  my ($self, $task) = @_;
  my %order = App::karr::Config->priority_order;
  return $order{$task->priority} // 2;
}

sub _count_overdue {
  my ($self, $tasks) = @_;
  my $now = gmtime->strftime('%Y-%m-%d');
  return scalar grep { $self->_is_overdue($_, $now) } @$tasks;
}

# One overdue test for the count and the section, so the header can never
# disagree with the list under it.
#
# `due: ""` satisfies the predicate but is not a date, and the empty string
# sorts before every real one -- so a kanban-md card carrying it was reported
# overdue for ever, with "due " and nothing after it. Empty means absent, as it
# does in pick (ticket #59).
sub _is_overdue {
  my ($self, $task, $now) = @_;
  return 0 unless $task->has_due && length $task->due;
  return 0 unless $task->due lt $now;
  return !$self->store->is_terminal_status($task->status);
}

sub _load_tasks {
  my ($self) = @_;
  return $self->load_tasks;
}

1;
