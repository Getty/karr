# ABSTRACT: Show board summary

package App::karr::Cmd::Board;
our $VERSION = '0.501';
use Moo;
use MooX::Cmd;
use MooX::Options (
  usage_string => 'USAGE: karr board [--json] [--compact] [--tags] [--done]',
);
use App::karr::Role::BoardAccess;
use App::karr::Role::Output;
use App::karr::Task;
use App::karr::Config;
use Term::ANSIColor qw( colored );

with 'App::karr::Role::BoardAccess', 'App::karr::Role::Output';

option tags => (
  is => 'ro',
  doc => 'Show each task\'s tags on an extra indented line',
);

option done => (
  is => 'ro',
  doc => 'Include the board\'s final column (hidden by default)',
);

=head1 SYNOPSIS

    karr board
    karr board --tags
    karr board --compact
    karr board --json
    karr board --done

=head1 DESCRIPTION

Renders a board-oriented summary grouped by status. The default output is a
compact, Markdown-flavoured plaintext board: the board name as an C<#> heading,
each status as a C<##> section, and one C<- id | title | meta...> line per task.
This stays readable when piped, redirected, diffed, or pasted. Colour is added
only when standard output is a terminal (and C<NO_COLOR> is unset). Compact and
JSON modes remain available for automation and scripting.

Archived tasks are not part of any of those renderings: they are left out of the
columns, out of the cards, and out of every number in the footer, in all output
modes. C<board> reports the columns the board works in; L<App::karr::Cmd::List>
with C<--archived> is where filed-away cards are read.

=head1 OUTPUT MODES

=over 4

=item * Default output

Lists every board column as a C<## Status> section (in board order, empty
sections included), except the board's final column, which is hidden unless
C<--done> is given. That column is C<done> on a default board and whatever the
board's last status is named on one imported from kanban-md. Each task renders
as C<- id | title> followed by C<priority> (non-default only), C<@claimant>,
C<blocked:reason>, and C<due:date> tokens where applicable. A footer line totals
tasks, claims, and blocks, and -- when the final column is hidden and non-empty
-- appends a hint naming what it withheld, so the count is not silently lost:
C<(2 done hidden)> on a default board, C<(2 shipped hidden)> where C<shipped> is
the final column.

=item * C<--tags>

Adds an extra indented line of C<#tag> tokens beneath each task that has tags.

=item * C<--done>

Includes the board's final column, which is hidden by default, and suppresses
the hidden-count footer hint. Applies to the default, C<--tags>, and C<--json>
renderings; C<--compact> always lists every column regardless.

=item * C<--compact>

Prints one line per board column in the form C<status(count): ids>.

=item * C<--json>

Emits the board name, total task count, and a structured C<columns> array with
per-column task lists. The final column is always present with its real count,
but carries an empty C<tasks> list unless C<--done> is given.

=back

=head1 SEE ALSO

L<karr>, L<App::karr>, L<App::karr::Cmd::List>, L<App::karr::Cmd::Show>,
L<App::karr::Cmd::Pick>, L<App::karr::Cmd::Context>

=cut

my %STATUS_COLOR = (
  backlog       => 'bright_black',
  todo          => 'cyan',
  'in-progress' => 'yellow',
  review        => 'magenta',
  done          => 'green',
);

my %PRIORITY_COLOR = (
  critical => 'bold red',
  high     => 'red',
  medium   => 'yellow',
  low      => 'bright_black',
);

sub execute {
  my ($self, $args_ref, $chain_ref) = @_;

  # Before anything is rendered: a repository with no board here would
  # otherwise print the default config over an empty task list, which is
  # byte-identical to a board that simply has no cards (#135). No sync -- see
  # App::karr::Role::BoardDiscovery/require_local_board.
  $self->require_local_board;

  my $ec = $self->store->effective_config;

  # `board` shows the board, and the archive is what a card is taken off the
  # board into: `archived` is not one of the columns, and archived cards are
  # dropped here -- before anything below groups, counts, renders or hides
  # them. kanban-md arrives at the same place in two steps (cmd/board.go
  # filters the task list with IsArchivedStatus, board.Summary iterates
  # cfg.BoardStatuses()), but unlike the context block of #229 this view is no
  # interop contract, so the reason it holds here is karr's own (#234):
  #
  #   * The footer has to count something a reader can name. With the archive
  #     in it, this repository's own board ended in "241 tasks (231 done
  #     hidden)" over ten rendered cards, one of which was a card deliberately
  #     taken off the board. "241 tasks" here and "241 tasks" from the
  #     reference counted different things, and nothing on the line said which
  #     of them was meant.
  #   * Once the archive is not counted, still rendering it would put cards on
  #     screen that the total leaves out -- the exact inverse of the "(N done
  #     hidden)" contract, where what is withheld is counted and the footer
  #     says so. A view that disagrees with its own total in both directions
  #     at once is worse than either whole answer.
  #   * --compact and --json never hid the empty archived column at all, so
  #     "the archive is not a column" is also the first rule about it that all
  #     three output modes share.
  #
  # Nothing is lost: `karr list --archived` reads the archive, `karr show ID` a
  # single filed card. As in #229, `archived` is archived whether or not the
  # board configures the column -- kanban-md's IsArchivedStatus additionally
  # requires it in the config, and two answers to "is this archived?" in one
  # distribution would be worse than the divergence.
  my @statuses = grep { $_ ne App::karr::Config->ARCHIVED_STATUS }
    $self->store->all_status_names;
  my @tasks = grep { $_->status ne App::karr::Config->ARCHIVED_STATUS }
    $self->load_tasks;

  my %by_status;
  for my $t (@tasks) {
    push @{$by_status{$t->status}}, $t;
  }

  if ($self->json) {
    my $board_name = $ec->{board}{name} // 'Kanban Board';
    my %board_data = (
      name     => $board_name,
      total    => scalar @tasks,
      columns  => [],
    );
    for my $status (@statuses) {
      my $tasks_in_status = $by_status{$status} // [];
      # Hide the finished column's payloads by default (keep the column and
      # its real count so the all-columns shape and total stay intact); --done
      # reveals them. Which column is finished is the board's own decision and
      # never the literal `done` -- an imported board ends in whatever it
      # named its last status, and asking for the literal here left `--done`
      # with nothing to do on such a board (#67, #234).
      my $hide = $self->store->is_terminal_status($status) && !$self->done;
      my %col = (
        status => $status,
        count  => scalar @$tasks_in_status,
        tasks  => $hide ? [] : [ map { $_->to_frontmatter } @$tasks_in_status ],
      );
      push @{$board_data{columns}}, \%col;
    }
    $self->print_json(\%board_data);
    return;
  }

  if ($self->compact) {
    for my $status (@statuses) {
      my $tasks_in_status = $by_status{$status} // [];
      my $count = scalar @$tasks_in_status;
      my $ids = join(',', map { $_->id } @$tasks_in_status);
      printf "%s(%d): %s\n", $status, $count, $ids || '-';
    }
    return;
  }

  my $board_name = $ec->{board}{name} // 'Kanban Board';

  # Colour only when writing to a real terminal — piped or redirected output
  # stays clean plaintext so the board diffs, greps, and pastes cleanly.
  my $color = -t STDOUT && !$ENV{NO_COLOR};
  my $c = sub {
    my ($text, $spec) = @_;
    return $color ? colored($text, $spec) : $text;
  };
  my $sep = $c->('|', 'bright_black');

  print $c->("# $board_name", 'bold cyan'), "\n";

  # Hide the board's finished column unless --done was given (the footer still
  # says how many cards it withheld). Asked of the store, so a board whose
  # last column is `shipped` hides shipped work instead of a `done` it does not
  # have (#67, #234). `archived` is not in @statuses at all -- see the top.
  my @display_statuses = grep {
    $self->done || !$self->store->is_terminal_status($_)
  } @statuses;

  for my $status (@display_statuses) {
    my $tasks  = $by_status{$status} // [];
    my $label  = join ' ', map { ucfirst } split /-/, $status;
    my $accent = $STATUS_COLOR{$status} // 'white';
    print "\n", $c->("## $label", "bold $accent"), "\n";

    for my $t (@$tasks) {
      my @meta;
      if ($t->priority && $t->priority ne 'medium') {
        push @meta, $c->('priority:' . $t->priority, $PRIORITY_COLOR{$t->priority} // 'white');
      }
      # A claim is only worth showing while the work is still live, and which
      # columns count as finished is the board's decision -- a board imported
      # from kanban-md can end in `shipped`, and every finished card there
      # still carried its claimant into the board (ticket #98, following #67).
      if ($t->has_claimed_by && !$self->store->is_terminal_status($t->status)) {
        push @meta, $c->('@' . $t->claimed_by, 'cyan');
      }
      if ($t->has_blocked) {
        my $reason = $t->has_block_reason ? $t->block_reason : undef;
        $reason = substr($reason, 0, 40) . '...' if defined $reason && length $reason > 43;
        push @meta, $c->(
          defined $reason && length $reason ? "blocked:$reason" : 'blocked', 'bold red');
      }
      if ($t->has_due) {
        push @meta, $c->('due:' . $t->due, 'yellow');
      }

      my $line = join ' ', $c->('-', 'bright_black'), $t->id, $sep, $t->title;
      $line .= " $sep " . join(" $sep ", @meta) if @meta;
      print $line, "\n";

      if ($self->tags && @{$t->tags}) {
        print '  ', $c->(join(' ', map { "#$_" } @{$t->tags}), 'bright_black'), "\n";
      }
    }
  }

  # Summary footer. Every count here is over @tasks, which is the board
  # without its archive (see the top) -- so the total says how many cards are
  # on this board, and `blocked` how many of those are stuck, rather than
  # either number silently including work that was filed away.
  my $blocked = grep { $_->has_blocked } @tasks;
  # Same test as the per-card `@claimant` token above, so the footer can never
  # count a claim the board itself does not show.
  my $claimed = grep { $_->has_claimed_by && !$self->store->is_terminal_status($_->status) } @tasks;
  # At most one status left in @statuses is terminal once `archived` is gone,
  # and it is the column @display_statuses withheld. The hint names it, so it
  # reads "(3 shipped hidden)" on a board that calls it that.
  my ($final_status) = grep { $self->store->is_terminal_status($_) } @statuses;
  my $hidden = ( defined $final_status && !$self->done )
    ? scalar @{ $by_status{$final_status} // [] } : 0;
  my $total_label = scalar(@tasks) . ' tasks';
  $total_label .= " ($hidden $final_status hidden)" if $hidden;
  my @summary = ( $total_label );
  push @summary, "$claimed claimed" if $claimed;
  push @summary, "$blocked blocked" if $blocked;
  print "\n", $c->(join('  ', @summary), 'bold'), "\n";
}

1;
