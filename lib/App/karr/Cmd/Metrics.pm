# ABSTRACT: Show flow metrics: throughput, lead/cycle time, flow efficiency, aging work

package App::karr::Cmd::Metrics;
our $VERSION = '0.500';
use Moo;
use MooX::Cmd;
use MooX::Options (
  usage_string => 'USAGE: karr metrics [--since YYYY-MM-DD] [--json] [--compact]',
);
use Time::Piece;
use App::karr::Role::BoardAccess;
use App::karr::Role::Output;
use App::karr::Config;

with 'App::karr::Role::BoardAccess', 'App::karr::Role::Output';

=head1 SYNOPSIS

    karr metrics
    karr metrics --since 2026-01-01
    karr metrics --compact
    karr metrics --json

=head1 DESCRIPTION

Reports the board's flow metrics: how much work finished lately, how long it
took, how much of that time the work was actually started, and what has been
in flight too long. Archived tasks are excluded from every figure, the way
they are excluded from C<list> and C<board>.

Like the other read commands (C<board>, C<list>, C<show>, C<log>, C<context>)
this one does not sync first, and it refuses a repository that holds no board
rather than reporting zeroes for it.

=head1 METRICS

Every number below is derived from the lifecycle stamps on the cards --
C<created>, C<started>, C<completed> -- and from nothing else. See
L</DATA SOURCE> for why, and for what that costs.

=over 4

=item * B<Throughput 7d / 30d>

How many tasks carry a C<completed> stamp inside the last 7 and 30 days. The
windows are fixed, as they are in kanban-md, so the two figures mean the same
thing on both tools; C<--since> narrows the population they are counted over
but does not move them.

=item * B<Average lead time>

Mean of C<completed - created> over every completed task: the whole time a
request existed, queue time included.

=item * B<Average cycle time>

Mean of C<completed - started> over every completed task that also carries a
usable start: the time from picking the work up to finishing it. karr stamps
C<started> whenever it stamps C<completed>, even for a card dragged straight
into a terminal status (see L<App::karr::Task/update_timestamps>), so on a
board written by a current karr the two populations are the same set. They
differ where a card was imported without a start, or carries one that precedes
its own creation (see L</DATA SOURCE>).

=item * B<Flow efficiency>

Cycle time as a fraction of lead time -- how much of a task's life was spent
being worked on rather than waiting. Computed over the tasks that contributed
to B<both> averages, and over their own lead time rather than the board's:
that is the one deliberate departure from kanban-md, which divides the average
cycle time by the average lead time even when the two averages were taken over
different populations. Where every completed card carries a usable start, the
two definitions produce the same number; where they do not, kanban-md's can
report an efficiency above 100%, which describes nothing.

=item * B<Aging work items>

Tasks that were started, are not in a terminal status, and carry no
completion, with the time since C<started>. Listed oldest first (karr's
refs hand tasks back in no particular order, so an explicit sort is needed
where kanban-md could lean on its file order).

=back

An average over no tasks is reported as C<--> rather than as C<0>, and the
default and compact renderings state how many tasks each average was taken
over, so a figure resting on two cards cannot be mistaken for one resting on
two hundred. Neither average is clamped: a card whose C<completed> precedes its
C<created> -- reachable by hand-editing, or by another tool -- contributes a
negative duration and is left visible as one, because a metrics command that
quietly normalises impossible data is how impossible data survives.

=head1 DATA SOURCE

The lifecycle stamps are the only source. Every status change goes through
L<App::karr::Role::TaskMutation/apply_status_change> or C<karr pick>, and both
stamp C<started> and C<completed> through the board's own config, so a board
karr wrote carries the timestamps these metrics need on the cards themselves.

The activity log (C<refs/karr/log/*>, L<App::karr::Cmd::Log>) is deliberately
not consulted. It is richer -- it dates individual writes -- but it only
exists for boards that were active after it was introduced, its entries record
the status a write left a task in rather than the transition it made, and the
bulk paths (C<import>, C<restore>, C<repair>) write refs without logging. A
cycle time reconstructed from it would be silently short on exactly the boards
whose history is oldest, and would disagree with the stamps on the cards.

Three limitations follow from that choice, and all three are visible in the
output rather than hidden:

=over 4

=item * A card whose C<completed> or C<started> was never stamped -- created
directly into a terminal status, or moved by a karr old enough to miss the
stamp on a board with non-default statuses -- is missing from the averages.
The per-average task counts are what expose it.

=item * A card carrying a timestamp that cannot be parsed at all (hand-edited,
or written by a third tool in an unexpected format) is counted in
C<unusable_timestamps> and named in a note, rather than being dropped silently.
Both karr's own C<YYYY-MM-DDTHH:MM:SSZ> and kanban-md's RFC3339 with a numeric
offset and optional fraction are understood, as is a bare C<YYYY-MM-DD>.

=item * A card whose C<started> precedes its own C<created> is counted there
too, and contributes no cycle time. karr wrote C<started> as a bare date until
ticket #68, and such a stamp reads as midnight -- earlier than a card created
later the same day, which is the normal case for a ticket picked up on the day
it was filed. karr's own board held 75 of them among 116 finished tickets when
this command was written, and counting them made its average cycle time exceed
its average lead time -- a flow efficiency of 107.3%.
The start is still good enough to say the work is in flight, so the aging list
below uses it.

=back

=head1 OUTPUT MODES

=over 4

=item * Default output

A Markdown-flavoured plaintext block: C<# Flow Metrics>, one C<label: value>
line per figure, and -- when there are any -- an C<## Aging Work Items>
section of C<- id | title | status | age:...> lines, the same line shape
C<karr board> uses.

=item * C<--compact>

One C<Throughput: ... | Lead: ... | Cycle: ... | Efficiency: ...> line,
followed by one C<Aging: #id [status] title (age)> line per aging item, as in
kanban-md's compact rendering.

=item * C<--json>

kanban-md's payload -- C<throughput_7d>, C<throughput_30d>,
C<avg_lead_time_hours>, C<avg_cycle_time_hours>, C<flow_efficiency>,
C<aging_items> -- plus C<lead_samples>, C<cycle_samples> and
C<unusable_timestamps>, so a consumer can tell a real zero from an empty
population. An average that has no samples is omitted, as it is there.
C<aging_items> is always present, as an empty array when nothing is aging.

=back

=head1 SEE ALSO

L<karr>, L<App::karr>, L<App::karr::Cmd::Board>, L<App::karr::Cmd::List>,
L<App::karr::Cmd::Context>, L<App::karr::Cmd::Log>, L<App::karr::Task>

=cut

option since => (
  is => 'ro',
  format => 's',
  doc => 'Only count tasks completed after this date (YYYY-MM-DD)',
);

=opt since

  karr metrics --since 2026-01-01

Drops every task completed on or before this date from the figures, so the
averages describe a chosen period instead of the whole board's history. Tasks
that are not completed at all are kept, so the aging list is unaffected --
kanban-md's C<--since> works the same way. The date is validated the way every
other date in karr is (L<App::karr::Config/validate_due>): calendar-correct
C<YYYY-MM-DD>, and a usage error otherwise.

=cut

use constant SHORT_WINDOW_DAYS => 7;
use constant LONG_WINDOW_DAYS  => 30;
use constant SECONDS_PER_HOUR  => 3600;
use constant SECONDS_PER_DAY   => 86400;

sub execute {
  my ($self, $args_ref, $chain_ref) = @_;

  # Option validation first, so a bad --since still exits 2 on a repository
  # that has no board (ADR 0002, the ordering require_local_board documents).
  my $since;
  if ( defined $self->since && length $self->since ) {
    eval { App::karr::Config->validate_due( $self->since ); 1 }
      or $self->usage_error(
        sprintf 'invalid --since date "%s" (expected YYYY-MM-DD)', $self->since );
    $since = _epoch( $self->since );
  }

  # Zeroes over an unread board would be the most confident possible way to be
  # wrong here: "throughput 0" reads as a board that shipped nothing, not as a
  # board that was never fetched (#135).
  $self->require_local_board;

  my $now = gmtime->epoch;
  my $window_short = $now - SHORT_WINDOW_DAYS * SECONDS_PER_DAY;
  my $window_long  = $now - LONG_WINDOW_DAYS * SECONDS_PER_DAY;

  # Archived work is out of every figure, as it is out of `list` and `board`
  # (and out of kanban-md's metrics, which filters on IsArchivedStatus).
  my @tasks = grep { $_->status ne App::karr::Config->ARCHIVED_STATUS }
    $self->load_tasks;

  my ( $throughput_short, $throughput_long ) = ( 0, 0 );
  my ( $lead_sum, $lead_n, $cycle_sum, $cycle_n, $paired_lead_sum ) = ( 0, 0, 0, 0, 0 );
  my @aging;
  my $unusable = 0;

  for my $task (@tasks) {
    my $created   = _epoch( $task->created );
    my $started   = $task->has_started   ? _epoch( $task->started )   : undef;
    my $completed = $task->has_completed ? _epoch( $task->completed ) : undef;

    # kanban-md filters the task list before computing; the effect is the same
    # and this keeps the parse in one place. Strictly after, as there: a task
    # completed at midnight of the --since date is not "after" it. A task with
    # no completion is kept either way, which is what leaves the aging list
    # unaffected by --since.
    next if defined $since && defined $completed && $completed <= $since;

    # A start that precedes the card's own creation is not a start anything can
    # be measured from. karr before 0.403 stamped `started` as a bare date
    # (ticket #68), which reads as midnight and so precedes a card created later
    # the same day: 75 of the 116 finished tickets on karr's own board carry one.
    # Counted, the cycle time of such a card exceeds its lead time, and the
    # board reports a flow efficiency above 100% -- exactly the confidently
    # wrong number this command exists not to print. The stamp is still good
    # enough to say the work is in flight, so aging below uses it either way.
    my $start_measurable =
      defined $started && ( !defined $created || $started >= $created );

    # Counted once per task, not once per stamp: what the reader needs to know
    # is how many cards are missing from the figures below. Counted after the
    # --since filter, so a card the caller asked to leave out is not reported
    # as one karr could not use.
    $unusable++
      if !defined $created
      || ( $task->has_started   && !defined $started )
      || ( $task->has_completed && !defined $completed )
      || ( defined $started     && !$start_measurable );

    if ( defined $completed ) {
      $throughput_short++ if $completed > $window_short;
      $throughput_long++  if $completed > $window_long;

      if ( defined $created ) {
        my $lead = ( $completed - $created ) / SECONDS_PER_HOUR;
        $lead_sum += $lead;
        $lead_n++;
        if ($start_measurable) {
          $cycle_sum += ( $completed - $started ) / SECONDS_PER_HOUR;
          $cycle_n++;
          # The efficiency denominator: the lead time of the same tasks the
          # cycle time was measured over. See the flow-efficiency entry in the
          # POD above for why this is not simply $lead_sum.
          $paired_lead_sum += $lead;
        }
      }
    }

    # Started, still open, no completion recorded. has_completed rather than
    # the parsed stamp on purpose: a card whose completion is merely unreadable
    # is finished work, and reporting it as aging would age it for ever. A
    # bare-date start is good enough here (an age measured in days is not
    # changed by which hour of the day the work began), which is why this asks
    # `defined $started` and not $start_measurable.
    if ( defined $started
      && !$task->has_completed
      && !$self->store->is_terminal_status( $task->status ) )
    {
      push @aging, {
        id        => $task->id + 0,
        title     => $task->title,
        status    => $task->status,
        age_hours => _round( ( $now - $started ) / SECONDS_PER_HOUR, 2 ),
      };
    }
  }

  # Oldest first: refs come back unordered, so without this the list would
  # shuffle between runs, and the item that most needs attention is the one
  # that has been in flight longest.
  @aging = sort { $b->{age_hours} <=> $a->{age_hours} || $a->{id} <=> $b->{id} } @aging;

  my $avg_lead  = $lead_n  ? $lead_sum / $lead_n   : undef;
  my $avg_cycle = $cycle_n ? $cycle_sum / $cycle_n : undef;
  my $efficiency =
    ( $cycle_n && $paired_lead_sum > 0 ) ? $cycle_sum / $paired_lead_sum : undef;

  if ( $self->json ) {
    $self->print_json( {
      throughput_7d         => $throughput_short,
      throughput_30d        => $throughput_long,
      lead_samples          => $lead_n,
      cycle_samples         => $cycle_n,
      unusable_timestamps   => $unusable,
      aging_items           => \@aging,
      ( defined $avg_lead   ? ( avg_lead_time_hours  => _round( $avg_lead,  2 ) ) : () ),
      ( defined $avg_cycle  ? ( avg_cycle_time_hours => _round( $avg_cycle, 2 ) ) : () ),
      ( defined $efficiency ? ( flow_efficiency      => _round( $efficiency, 4 ) ) : () ),
    } );
    return;
  }

  if ( $self->compact ) {
    printf "Throughput: %d/7d %d/30d | Lead: %s | Cycle: %s | Efficiency: %s\n",
      $throughput_short, $throughput_long,
      _duration_or_dash($avg_lead), _duration_or_dash($avg_cycle),
      _percent_or_dash($efficiency);
    printf "Aging: #%d [%s] %s (%s)\n",
      $_->{id}, $_->{status}, $_->{title}, _format_duration( $_->{age_hours} )
      for @aging;
    print _unusable_note($unusable) if $unusable;
    return;
  }

  print "# Flow Metrics\n\n";
  printf "%-17s%s\n", 'Throughput 7d:',  _count_label($throughput_short);
  printf "%-17s%s\n", 'Throughput 30d:', _count_label($throughput_long);
  printf "%-17s%s\n", 'Avg lead time:',  _average_label( $avg_lead,  $lead_n );
  printf "%-17s%s\n", 'Avg cycle time:', _average_label( $avg_cycle, $cycle_n );
  printf "%-17s%s\n", 'Flow efficiency:', _percent_or_dash($efficiency);

  if (@aging) {
    print "\n## Aging Work Items\n\n";
    printf "- %d | %s | %s | age:%s\n",
      $_->{id}, $_->{title}, $_->{status}, _format_duration( $_->{age_hours} )
      for @aging;
  }

  # An empty board must say what it means. Every figure above is legitimately
  # blank in that state, and a page of dashes and zeroes reads like a bug.
  print "\nNothing to measure yet: no task on this board carries a start or a\n"
    . "completion stamp.\n"
    if !$lead_n && !$cycle_n && !@aging;

  print "\n", _unusable_note($unusable) if $unusable;
}

# What the averages left out, and why. Never silent: a card missing from a
# figure is the one thing a metrics command must not hide.
sub _unusable_note {
  my ($count) = @_;
  return sprintf
    "Note: %d task%s carr%s a timestamp karr could not use -- unreadable, or a\n"
    . "start that precedes the card's own creation -- and %s left out of the\n"
    . "averages that need it.\n",
    $count, ( $count == 1 ? '' : 's' ), ( $count == 1 ? 'ies' : 'y' ),
    ( $count == 1 ? 'is' : 'are' );
}

sub _count_label {
  my ($count) = @_;
  return sprintf '%d task%s', $count, ( $count == 1 ? '' : 's' );
}

sub _average_label {
  my ( $hours, $samples ) = @_;
  return '--' unless defined $hours;
  return sprintf '%s (over %d task%s)', _format_duration($hours), $samples,
    ( $samples == 1 ? '' : 's' );
}

sub _duration_or_dash {
  my ($hours) = @_;
  return defined $hours ? _format_duration($hours) : '--';
}

sub _percent_or_dash {
  my ($ratio) = @_;
  return defined $ratio ? sprintf( '%.1f%%', $ratio * 100 ) : '--';
}

# kanban-md's FormatDuration (internal/output/table.go): days and hours once
# there is a whole day, hours and minutes below that, truncated rather than
# rounded. The sign is handled here and not there, because a hand-edited card
# can carry a completion older than its creation, and Perl's % on a negative
# operand would turn that into a nonsense figure rather than a negative one.
sub _format_duration {
  my ($hours) = @_;
  my $sign = $hours < 0 ? '-' : '';
  $hours = abs $hours;
  my $whole_hours = int $hours;
  my $days        = int( $whole_hours / 24 );
  my $rest_hours  = $whole_hours % 24;
  return sprintf '%s%dd %dh', $sign, $days, $rest_hours if $days > 0;
  return sprintf '%s%dh %dm', $sign, $rest_hours, int( $hours * 60 ) % 60;
}

sub _round {
  my ( $value, $places ) = @_;
  # Through sprintf and back into a number, so --json carries 2.34 rather than
  # 2.3399999999999999 and the same run always prints the same digits.
  return 0 + sprintf( "%.${places}f", $value );
}

# Every timestamp shape a karr board can hold, as epoch seconds, or undef when
# the value is none of them.
#
#   * karr's own writer:  2026-08-12T09:41:03Z
#   * kanban-md's:        2026-08-12T11:41:03.449764553+02:00 (RFC3339Nano,
#                         local offset, sub-second precision)
#   * a pre-0.403 karr `started`, and any hand-written date: 2026-08-12
#
# App::karr::Role::ClaimTimeout parses the first two for claim expiry and has
# the long-form reasoning; this is the same grammar with the bare date added,
# which that role deliberately does not accept (a claim stamp is never one).
# Duplicated rather than shared because the role's parser is private to it and
# answers a different question -- see the report on ticket #126.
#
# Sub-second precision is dropped: nothing here is measured in less than a
# minute. An offset-less stamp is read as UTC, which is what karr's own writer
# means by it.
sub _epoch {
  my ($stamp) = @_;
  return undef unless defined $stamp && length $stamp;
  my ( $date, $time, $offset ) = $stamp =~ m{
      \A (\d{4}-\d{2}-\d{2})                # calendar date
         (?: T (\d{2}:\d{2}:\d{2})          # civil time, optional
             (?: \. \d+ )?                  # fractional seconds, dropped
             ( Z | [+-]\d{2}:?\d{2} )?      # UTC offset, or none
         )?
      \z
  }x or return undef;
  $time //= '00:00:00';
  # Time::Piece's %z wants +hhmm and does not know "Z" at all.
  $offset = '+0000' if !defined $offset || uc($offset) eq 'Z';
  $offset =~ s/://;
  my $parsed =
    eval { Time::Piece->strptime( "${date}T${time}${offset}", '%Y-%m-%dT%H:%M:%S%z' ) };
  return defined $parsed ? $parsed->epoch : undef;
}

1;
