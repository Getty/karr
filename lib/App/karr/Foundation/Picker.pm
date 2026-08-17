# ABSTRACT: karr-foundation ticket selection — the one card a ticket-mode run is about

package App::karr::Foundation::Picker;
our $VERSION = '0.501';
use Moo;
use App::karr::Config;

=head1 DESCRIPTION

L<App::karr::Foundation::Picker> answers one question for
L<App::karr::Foundation>'s C<< mode: ticket >>: which card is this agent run
about? It applies C<karr pick>'s eligibility rules and C<karr pick>'s ranking
to one board and returns a task id -- and stops there. It claims nothing, locks
nothing and writes nothing.

That is the whole difference to L<App::karr::Cmd::Pick>, and it is deliberate.
Foundation already holds the board's F<.karr.lock> for the length of the run
and the fleet rule is one agent per repository, so nothing else can take the
card while the run lasts; a second owner would only add a claim with a lifetime
nobody watches. The claim belongs to the agent, which mints its own name with
C<karr agentname> and has to keep using that same name for C<move> and
C<handoff> (#176) -- a name foundation invented could not be handed over
without inventing a protocol for it. So an agent that dies mid-run leaves at
most its own claim, cleared by the board's C<claim_timeout> or by
C<karr unlock>, exactly as it does today.

The role composed here is what supplies C<claim_timeout_secs>/C<_claim_expired>:
reading an expired claim correctly means parsing an RFC3339 stamp that may
carry a fraction and an offset (#57), and that parser exists once, in
L<App::karr::Role::ClaimTimeout>. Foundation has to see expiry, or a crashed
agent's claim would take its card out of the assignable set for good and a
board whose only open card carries such a claim would go quiet for ever --
nothing would run, so nothing would reap the claim.

=cut

has store => (
  is       => 'ro',
  required => 1,
);

# The role's other two required names. It wants them for check_claim's
# reporting half (App::karr::Role::ClaimTimeout/expired_claim_report), which
# nothing here calls -- selection only ever asks _claim_expired. foundation has
# no --json and no --quiet, and it says what it did through .karr.log, so these
# answer for the shape of that: never JSON, never printing.
sub json  { 0 }
sub quiet { 1 }

# Composed here, not at the top of the file: Moo applies a role at the point
# the "with" stands, and this role requires the three names above it.
with 'App::karr::Role::ClaimTimeout';

sub next_ticket {
  my ( $self ) = @_;
  my $store   = $self->store;
  my $timeout = $self->claim_timeout_secs;

  my @candidates = grep { $self->_assignable( $_, $timeout ) } $store->load_tasks;
  return undef unless @candidates;

  # The same ordering App::karr::Cmd::Pick ranks by, from the same two config
  # lists: lower class index is more urgent, higher priority index is more
  # urgent, ties break on the id. The two have to agree -- foundation naming
  # a card the agent's own `karr pick` would not have handed it is a
  # coordinator arguing with its own board -- and today they agree by being
  # written the same way twice. That duplication is the smallest thing that
  # ships ticket mode without reaching into a command class from here; the one
  # definition it wants belongs with the pick rules themselves (#198).
  my $cfg        = App::karr::Config->from_merged( $store->effective_config );
  my @priorities = $cfg->priorities;
  my @classes    = $cfg->classes;
  my %pri_idx; $pri_idx{ $priorities[$_] } = $_ for 0 .. $#priorities;
  my %cls_idx; $cls_idx{ $classes[$_] }    = $_ for 0 .. $#classes;
  my $max_pri     = $#priorities;
  my $std_cls_idx = $cls_idx{standard} // 0;

  my ( $first ) = sort {
    ( ( $cls_idx{ $a->class } // $std_cls_idx ) <=> ( $cls_idx{ $b->class } // $std_cls_idx ) )
      || ( ( $max_pri - ( $pri_idx{ $a->priority } // -1 ) )
        <=> ( $max_pri - ( $pri_idx{ $b->priority } // -1 ) ) )
      || $a->id <=> $b->id
  } @candidates;

  return $first->id;
}

=method next_ticket

    my $id = App::karr::Foundation::Picker->new( store => $store )->next_ticket;

The id of the card a C<< mode: ticket >> run should be about, or C<undef> when
the board has none to give. Eligibility mirrors
L<App::karr::Cmd::Pick/_is_pickable> with C<--status> and C<--tags> absent: not
in a terminal status (the board's own final column and C<archived>, not a
hardcoded C<done>), not blocked, and not held by a live claim -- a claim past
the board's C<claim_timeout> no longer blocks anybody here either. Ranking is
C<karr pick>'s: class of service, then priority, then id.

Nothing is written and nothing is locked, so the answer is a hint that ages:
by the time the agent reads it the card may have moved. That is the same
staleness every C<karr> client lives with, and foundation's per-repo lock plus
the one-agent-per-repository rule is what keeps it from mattering within a run.

=cut

# Unmet dependencies are deliberately not filtered here, matching `karr pick`:
# nothing about depends_on blocks anything in karr, the command hands the card
# over and warns (#123). Filtering here would make foundation stricter than the
# board it coordinates.
sub _assignable {
  my ( $self, $task, $timeout ) = @_;
  return 0 unless $task;
  return 0 if $self->store->is_terminal_status( $task->status );
  return 0 if $task->has_blocked;
  # `claimed_by: ""` is how kanban-md spells "unclaimed" and Moo's predicate
  # calls it set, so the length test is not redundant (#59).
  return 0
    if $task->has_claimed_by
    && length $task->claimed_by
    && !$self->_claim_expired( $task, $timeout );
  return 1;
}

1;
