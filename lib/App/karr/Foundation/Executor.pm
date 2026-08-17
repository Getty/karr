# ABSTRACT: karr-foundation chain executor -- picks a ready step, runs it, writes its state back

package App::karr::Foundation::Executor;
our $VERSION = '0.501';
use Moo;
use POSIX qw( strftime );
use Sys::Hostname ();
use Try::Tiny;
use Path::Tiny;
use App::karr::Error qw( user_error clean_error );
use App::karr::Git;

=head1 SYNOPSIS

    karr-foundation chain              # execute what is ready
    karr-foundation chain --dry-run    # say what would run, touch nothing

=head1 DESCRIPTION

The VM. L<App::karr::Foundation::ChainStore> holds the program -- the planned
steps, their edges, their prechecks and the log of the runs that worked through
them -- and this is what executes it: it takes a step the chain says is ready,
measures the facts its precheck asks about, runs it, and writes back what
happened.

=head2 A layer above the repo modes, not a fourth one beside them

C<drain>, C<single> and C<ticket> are per-repository settings, and the chain is
fleet-wide. A C<mode: chain> in a F<.karr> file could not answer the only
question that matters here -- B<which step of the DAG is next> -- because that
answer lives in the hub and is about every repository at once. So the executor
is the B<caller> of those modes rather than their sibling:

    pull refs/karr-foundation/*
    ready_steps()
      kind: ticket   -> the existing ticket-mode path in the target repo
      kind: shell    -> the command, in the target repo, under its own lock
    update_step (CAS) + log_run
    push refs/karr-foundation/*

A C<kind: ticket> step therefore inherits the board lock, the claim discipline,
the C<#158> ownership guard and the run's own report from ticket mode
(L<App::karr::Foundation/_drain_repo>) instead of carrying a second copy of
them, and ticket mode stays a unit that can be tested on its own.

=head2 Pull before reading, push before working

The compare-and-swap on a step (L<App::karr::Foundation::ChainStore/update_step>)
is the B<second> line of defence, not the first. Two machines that never
exchange refs would each read C<pending> out of their own clone and each win
their own local CAS, so the ordering is what actually keeps one step to one
machine:

=over 4

=item * B<pull first>, and refuse the tick when the pull fails. Everywhere else
in F<karr-foundation> a failed fetch is a warning, because the fallback is this
machine's own view and that is the safe direction. Here the fallback is running
a step somebody else is already running, so the tick stops instead.

=item * B<push the claim before the work starts.> The window that matters is
the length of the step, not the length of the write: a claim published after a
half-hour agent run would have left the step readable as C<pending> for that
half hour. A claim that cannot be published is rolled back to C<pending>
locally -- no other machine ever saw it -- and the step is left for the next
tick.

=item * B<push the result, and the run log with it.> That push is best-effort:
the work has already happened, the state is written locally, and the next tick
publishes it. Refusing to record a run that is over would be the worse answer.

=back

=head2 Who measures the facts

C<ChainStore> reads the precheck grammar and evaluates it, and deliberately
measures nothing: measuring a fact means reading a board, and reading a board is
execution. This class is where execution lives, so this is where the facts come
from (L</facts_for>). The vocabulary is small and every entry comes off B<one>
board read:

    board_actionable    yes | no     any task an agent could still pick
    ticket_status       the status of the step's own ticket
    ticket_blocked      yes | no
    ticket_claimed      the claim name on it, or the empty string

A fact that cannot be measured -- a repository that is not a board, a ticket
that is not on it -- is B<absent>, and an absent fact makes a precheck not hold
whichever operator it uses (L<App::karr::Foundation::ChainStore/precheck_holds>).
That is the direction that costs a planning round rather than whatever the step
would have done.

=head2 What a failure does to the DAG

Nothing, and that is the design rather than an omission.
L<App::karr::Foundation::ChainStore/ready_steps> releases a step only when every
step it C<needs> is C<done>, so a step that ends C<failed> or C<stale> stops its
own branch B<by construction>:
its dependents never become ready, no cascade has to be computed, and every
branch that does not run through it carries on. The chain then cannot finish,
and that unreachability is exactly the signal C<on_stall: plan> names.

The planner itself is not built here. Where the spec says "call the planner"
this executor B<records that the planner is wanted> -- a C<planner> entry in the
run log naming the step and why, and a line of output at the end of the tick --
and does nothing else. Nothing is written that a future planner would have to
undo.

Three outcomes are deliberately B<not> failures, because none of them is a
statement about the plan:

=over 4

=item * A B<common error> (a rate-limited or broken agent command) requeues the
step to C<pending>. The board's own cooldown and the agent's availability record
have already been written by the drain; the step is simply not this machine's
to run right now.

=item * A B<skipped board> -- disabled, locked by another tick, in cooldown, or
on an agent that is currently failing -- requeues the step the same way and says
which of those it was.

=item * A step naming a B<repository this machine does not have> is left
untouched and unclaimed. The chain is shared and the machines are not, so this
is the ordinary case in a fleet, not a broken plan.

=back

=head2 What this executor does not do yet

C<kind: question> and C<kind: plan> steps are recognised and B<left pending>,
with the planner recorded as wanted and a line saying so. Running a question
against the mailbox is its own ticket (the mailbox and its C<resolve> already
exist, L<App::karr::Foundation::Questions>), and so is resolving cross-board
links automatically (L<App::karr::CrossBoard>). Both hang off the dispatch on
C<kind> at the top of one step and off L</facts_for>'s table, which is why each
of them is one place rather than a thread through this class.

Steps are executed one at a time within a tick. Concurrency in the chain is
across machines -- which is what the pull/claim/push ordering above buys -- and
the machine-local concurrency of several boards at once stays where it already
is (L<App::karr::Foundation::Limits> and the concurrent runner).

=head1 SEE ALSO

L<App::karr::Foundation>, L<App::karr::Foundation::ChainStore>,
L<App::karr::Foundation::Questions>

=cut

=attr foundation

The owning L<App::karr::Foundation>, held weakly. Required.

=cut

has foundation => (
  is       => 'ro',
  weak_ref => 1,
  required => 1,
);

=attr store

The hub's L<App::karr::Foundation::ChainStore>. Built from the foundation's
C<hub:> setting, and a user error when there is none: the chain is fleet state,
and executing a plan nobody else can see is not a smaller version of executing
the fleet's plan -- the same argument the question mailbox makes.

=cut

has store => (
  is      => 'lazy',
  builder => '_build_store',
);

sub _build_store {
  my ( $self ) = @_;
  return $self->foundation->_chain_store // user_error(
      'No usable hub repository: the chain lives in '
    . 'refs/karr-foundation/chain/* in the fleet hub, so name one with '
    . "'hub: /path/to/repo' in " . $self->foundation->_config_path );
}

sub _now { return strftime( '%Y-%m-%dT%H:%M:%SZ', gmtime() ) }

sub _say { my ( $self, $msg ) = @_; print "$msg\n"; return }

# ---------------------------------------------------------------------------
# The tick
# ---------------------------------------------------------------------------

=method run

    my $exit = $executor->run;

One tick of the VM: pull the fleet namespace, take every step the chain says is
ready, and work through them. Returns a process exit code -- C<1> only when the
tick refused to start (the fleet namespace could not be pulled), C<0> otherwise,
including when steps failed. A failed step is a statement about the plan, not
about F<karr-foundation>.

Steps that become ready B<because> of this tick's own work are picked up in a
further round, each round preceded by a fresh pull, so a linear chain does not
need one cron tick per step. A step is considered at most once per tick, which
is what bounds the rounds and what keeps a requeued step from spinning.

With C<--dry-run> nothing is pulled, claimed, executed or written: the ready
set is listed with the verdict each precheck currently gives.

=cut

sub run {
  my ( $self ) = @_;
  my $store = $self->store;

  return $self->_preview if $self->foundation->dry_run;

  # Before anything reads the chain (#186/#190). A tick that skipped this and
  # ran from its own clone would be executing a plan another machine has
  # already worked through.
  return 1 unless $self->_pull;

  my $header = $store->header;
  my $chain  = $header->{id};
  unless ( defined $chain ) {
    $self->_say( 'No chain in ' . $self->_hub . " \x{2014} nothing to execute "
      . '(a planner writes one into refs/karr-foundation/chain/)' );
    return 0;
  }

  my $run = $store->new_run_id;
  $store->log_run( $run, event => 'start', chain => $chain,
    host => Sys::Hostname::hostname(), pid => $$ );

  my ( %seen, %tally, @planner );
  while ( 1 ) {
    my @ready = grep { !$seen{ $self->_key($_) } } $store->ready_steps;
    last unless @ready;
    for my $step ( @ready ) {
      $seen{ $self->_key($step) } = 1;
      my $verdict = $self->_do_step( $run, $step );
      $tally{ $verdict->{state} }++;
      push @planner, [ $step->{id}, $verdict->{planner} ] if $verdict->{planner};
    }
    # A fresh view before the next round, for the same reason as the first
    # pull: the steps this round unblocked are ready for every machine, not
    # only for this one.
    last unless $self->_pull;
  }

  $store->log_run( $run, event => 'end', chain => $chain,
    map { ( $_ => $tally{$_} ) } sort keys %tally );
  $self->_push;

  $self->_report( $chain, \%tally, \@planner );
  return 0;
}

# One step is identified by the chain it belongs to as well as by its id: a
# planner that replaces the chain between two rounds may reuse an id, and a
# tick that had already seen the old step would skip the new one for ever.
sub _key {
  my ( $self, $step ) = @_;
  return ( $step->{chain} // '-' ) . '/' . ( $step->{id} // '-' );
}

sub _hub {
  my ( $self ) = @_;
  my $git = $self->foundation->_hub_git or return '(no hub)';
  return $git->dir;
}

sub _report {
  my ( $self, $chain, $tally, $planner ) = @_;
  my @parts = map { "$tally->{$_} $_" } sort keys %$tally;
  $self->_say( "chain $chain: " . ( @parts ? join( ', ', @parts ) : 'nothing ready' ) );
  return unless @$planner;

  # The seam the planner ticket lands on. Said out loud rather than only
  # written into the run log, because the operator running this by hand is the
  # planner until there is one.
  $self->_say( 'the planner is wanted for step(s) '
    . join( ', ', map { "$_->[0] ($_->[1])" } @$planner )
    . " \x{2014} no planner runs from here yet; re-plan the chain" );
  return;
}

# What --dry-run answers: the ready set and what each precheck says about it
# right now. Nothing is pulled either -- a dry run that fetched would be the
# one part of a tick it still performed.
sub _preview {
  my ( $self ) = @_;
  my $store  = $self->store;
  my $chain  = $store->header->{id};
  unless ( defined $chain ) {
    $self->_say( 'No chain in ' . $self->_hub . " \x{2014} nothing to execute" );
    return 0;
  }
  my @ready = $store->ready_steps;
  $self->_say( "chain $chain: " . scalar(@ready) . ' step(s) ready (dry run, '
    . 'nothing pulled, claimed or executed)' );
  for my $step ( @ready ) {
    my $facts = $self->facts_for( $step );
    my $holds = $store->precheck_holds( $step, $facts );
    $self->_say( '  ' . $self->_describe($step) . ': '
      . ( $holds ? 'would run' : $self->_stale_reason( $step, $facts ) ) );
  }
  return 0;
}

sub _describe {
  my ( $self, $step ) = @_;
  my $what = "step $step->{id} ($step->{kind}";
  $what .= " $step->{ticket}" if defined $step->{ticket};
  $what .= ')';
  $what .= " in $step->{repo}" if defined $step->{repo};
  return $what;
}

# ---------------------------------------------------------------------------
# One step
# ---------------------------------------------------------------------------

# Returns { state => done|failed|stale|pending|declined|skipped,
#           planner => $why_or_undef }. The state is what happened to the step,
# not what the command exited with.
sub _do_step {
  my ( $self, $run, $step ) = @_;
  my $store = $self->store;
  my $id    = $step->{id};
  my $kind  = $step->{kind} // '';

  # A kind this executor does not run. Left pending and unclaimed on purpose:
  # a question step waits for the mailbox and a plan step waits for the
  # planner, and neither is this ticket's to run. Its dependents wait with it,
  # which is the honest state of a chain that has reached something nothing
  # here can do.
  unless ( $kind eq 'ticket' || $kind eq 'shell' ) {
    $self->_say( $self->_describe($step)
      . ": left pending \x{2014} this foundation runs kind: ticket and "
      . 'kind: shell' );
    $store->log_run( $run, event => 'step', step => "$id", kind => $kind,
      state => 'pending', detail => 'kind not executed here' );
    # Recorded as wanting the planner for the same reason a failure is: a chain
    # that cannot proceed must not do it quietly. It is the only signal that
    # exists today -- once a question step runs against the mailbox it will be
    # executed rather than re-planned, and this branch is where that lands.
    $store->log_run( $run, event => 'planner', step => "$id", policy => 'plan',
      reason => "kind: $kind is not executed here" );
    $self->_push;
    return { state => 'skipped', planner => "kind: $kind is not executed here" };
  }

  # A repository this machine does not have is the ordinary case in a fleet:
  # the chain is shared state, the working copies are not. Nothing is claimed,
  # nothing is logged, and the machine that does have it runs the step.
  my $repo = defined $step->{repo} ? path( $step->{repo} ) : undef;
  unless ( $repo && $repo->is_dir ) {
    $self->foundation->_say_verbose( $self->_describe($step)
      . ": not on this machine \x{2014} left for one that has it" );
    return { state => 'skipped' };
  }

  # The board, before the facts are measured off it. Without this the precheck
  # would be evaluated against whatever this clone last happened to fetch,
  # which is the same mistake the fleet-namespace pull above exists to avoid.
  return $self->_requeue( $run, $step, 'the board could not be pulled' )
    unless $self->_pull_board( $repo );

  my $facts = $self->facts_for( $step );

  unless ( $store->precheck_holds( $step, $facts ) ) {
    return $self->_stale( $run, $step, $self->_stale_reason( $step, $facts ) );
  }

  # A ticket step whose card is not on the board is a plan that has gone out of
  # date in the one way a precheck cannot express: there is nothing to be
  # about. Stale, for the same reason and at the same cost as any other stale
  # step. Whether the card is blocked or already done is deliberately NOT
  # asked here -- that is what a precheck is for, and karr does not get to be
  # cleverer than the plan it was given.
  if ( $kind eq 'ticket' && !exists $facts->{ticket_status} ) {
    return $self->_stale( $run, $step,
      "ticket $step->{ticket} is not on the board in $repo" );
  }

  # ----- claim, and publish the claim before any work starts -----
  my $claimed = $store->update_step( $id, sub {
    my ( $current ) = @_;
    return undef unless ( $current->{state} // 'pending' ) eq 'pending';
    return undef unless ( $current->{chain} // '' ) eq ( $step->{chain} // '' );
    $current->{state}    = 'running';
    $current->{started}  = _now();
    $current->{attempts} = ( $current->{attempts} // 0 ) + 1;
    return $current;
  } );
  unless ( $claimed ) {
    $self->foundation->_say_verbose(
      $self->_describe($step) . ': taken by another tick' );
    return { state => 'declined' };
  }

  $store->log_run( $run, event => 'step', step => "$id", kind => $kind,
    state => 'running', repo => "$repo",
    ( defined $step->{ticket} ? ( ticket => "$step->{ticket}" ) : () ) );

  unless ( $self->_push ) {
    # Nobody else ever saw this claim, so taking it back costs nothing and
    # leaving it would park the step as `running` on a machine that is not
    # running it.
    $store->update_step( $id, sub {
      my ( $current ) = @_;
      return undef unless ( $current->{state} // '' ) eq 'running';
      $current->{state} = 'pending';
      delete $current->{started};
      return $current;
    } );
    $self->_say( $self->_describe($step)
      . ": claim could not be published \x{2014} left for the next tick" );
    return { state => 'declined' };
  }

  # ----- run it -----
  my $verdict = $kind eq 'ticket'
    ? $self->_run_ticket_step( $step, $repo )
    : $self->_run_shell_step( $step, $repo );

  return $self->_requeue( $run, $step, $verdict->{detail} )
    if $verdict->{state} eq 'pending';
  return $self->_finish( $run, $step, $verdict );
}

# ---------------------------------------------------------------------------
# The two kinds
# ---------------------------------------------------------------------------

# Into the existing ticket-mode path (#185), which is what makes this a layer
# above the repo modes rather than a fourth one: the lock, the cooldown, the
# agent availability, the claim discipline, the ownership guard on the
# auto-block and the run's own report all come from there. What the chain adds
# is which card, and how long it may take.
sub _run_ticket_step {
  my ( $self, $step, $repo ) = @_;

  my $result = try {
    $self->foundation->_process_repo( $repo,
      ticket => $step->{ticket},
      ( defined $step->{timeout} ? ( timeout => $step->{timeout} ) : () ),
    );
  } catch {
    # A local problem -- a mode this machine cannot read, an agent definition
    # it does not have -- says nothing about the plan, so the step goes back
    # rather than down.
    { outcome => 'skipped', reason => clean_error($_) };
  };

  my $outcome = $result->{outcome} // 'error';
  return { state => 'pending', detail => 'board skipped: ' . ( $result->{reason} // '?' ) }
    if $outcome eq 'skipped';
  return { state => 'pending', detail => 'the agent command failed: '
    . ( $result->{error} // 'common error' ) }
    if $outcome eq 'common-error';
  return { state => 'done', outcome => $outcome, exit => $result->{exit},
    detail => 'the ticket moved' }
    if $outcome eq 'progress';
  return { state => 'failed', outcome => $outcome, exit => $result->{exit},
    detail => "the ticket did not move ($outcome)" };
}

# A command in a repository, under that repository's own lock and with the
# runner's process group, timeout and tee -- the same apparatus the on_drained
# hook borrows (#193), and for the same reason: a chain step that builds out of
# a working tree must not have another tick's agent walk into it. It runs as
# KARR_ROLE=chain, so any karr write it makes lands in its own activity log
# rather than counting as an agent's engagement with a card.
sub _run_shell_step {
  my ( $self, $step, $repo ) = @_;
  my $f   = $self->foundation;
  my $cmd = $step->{command};

  return { state => 'failed', detail => 'a shell step needs a command' }
    unless defined $cmd && length $cmd;

  # The board's own opt-out wins here as it does everywhere else: it is
  # synchronised board state, and "no automated runs in this repository" does
  # not become smaller because the run was planned in the hub. Pending, not
  # failed -- the person who disabled the board is the one who can enable it.
  return { state => 'pending', detail => 'the board is disabled' }
    if $f->_board_disabled( $repo );

  return { state => 'pending', detail => 'the board lock is held' }
    unless $f->_acquire_lock( $repo );

  my ( $exit ) = try {
    $f->_run_command( $repo, $f->_load_karr( $repo ), $cmd, undef, undef,
      role => 'chain',
      ( defined $step->{timeout} ? ( max_runtime => $step->{timeout} ) : () ),
    );
  } catch {
    ( -1 );
  };
  $f->_release_lock( $repo );

  return { state => 'done', exit => $exit, detail => 'exit=0' } if $exit == 0;
  return { state => 'failed', exit => $exit, detail => "exit=$exit" };
}

# ---------------------------------------------------------------------------
# Writing a step back
# ---------------------------------------------------------------------------

sub _finish {
  my ( $self, $run, $step, $verdict ) = @_;
  my $store = $self->store;
  my $id    = $step->{id};
  my $state = $verdict->{state};

  $store->update_step( $id, sub {
    my ( $current ) = @_;
    return undef unless ( $current->{state} // '' ) eq 'running';
    $current->{state}    = $state;
    $current->{finished} = _now();
    $current->{result}   = {
      at   => _now(),
      run  => $run,
      ( defined $verdict->{outcome} ? ( outcome => $verdict->{outcome} ) : () ),
      ( defined $verdict->{exit}    ? ( exit    => $verdict->{exit} )    : () ),
      ( defined $verdict->{detail}  ? ( detail  => $verdict->{detail} )  : () ),
    };
    return $current;
  } );
  $store->log_run( $run, event => 'step', step => "$id", state => $state,
    ( defined $verdict->{detail} ? ( detail => $verdict->{detail} ) : () ) );
  $self->_push;

  $self->_say( $self->_describe($step) . ": $state \x{2014} "
    . ( $verdict->{detail} // '' ) );

  return { state => $state } unless $state eq 'failed';

  # on_stall, at the seam. The policy the spec writes is `plan`, and this
  # executor cannot plan -- so it records that the planner is wanted instead
  # of pretending, and the dependents of this step simply never become ready
  # (ready_steps releases a step only when every step it needs is done), which
  # is the branch pruning itself without anybody computing a cascade.
  my $policy = $step->{on_stall} // 'plan';
  $store->log_run( $run, event => 'planner', step => "$id",
    policy => "$policy", reason => ( $verdict->{detail} // 'the step failed' ) );
  return { state => $state, planner => "on_stall: $policy" };
}

# Back to pending: nothing about the plan was learned, so nothing about the
# plan is written down. The attempt counter the claim bumped stays as it is --
# it is the record of how often this step has been tried, which is what makes
# a step that can never run visible to whoever reads the chain.
sub _requeue {
  my ( $self, $run, $step, $detail ) = @_;
  my $store = $self->store;
  my $id    = $step->{id};

  $store->update_step( $id, sub {
    my ( $current ) = @_;
    return undef if ( $current->{state} // 'pending' ) eq 'pending';
    $current->{state} = 'pending';
    delete $current->{started};
    $current->{result} = { at => _now(), run => $run, detail => $detail };
    return $current;
  } );
  $store->log_run( $run, event => 'step', step => "$id", state => 'pending',
    detail => $detail );
  $self->_push;
  $self->_say( $self->_describe($step) . ": requeued \x{2014} $detail" );
  return { state => 'pending' };
}

sub _stale {
  my ( $self, $run, $step, $reason ) = @_;
  my $store = $self->store;
  $store->mark_stale( $step->{id}, $reason );
  $store->log_run( $run, event => 'step', step => "$step->{id}",
    state => 'stale', detail => $reason );
  $store->log_run( $run, event => 'planner', step => "$step->{id}",
    policy => 'plan', reason => $reason );
  $self->_push;
  $self->_say( $self->_describe($step) . ": stale \x{2014} $reason" );
  return { state => 'stale', planner => 'the precheck no longer holds' };
}

sub _stale_reason {
  my ( $self, $step, $facts ) = @_;
  my $p = $self->store->parse_precheck( $step->{precheck} )
    or return 'the precheck no longer holds';
  my $have = exists $facts->{ $p->{fact} }
    ? "'" . $facts->{ $p->{fact} } . "'"
    : 'not measurable here';
  return "precheck '$step->{precheck}' no longer holds ($p->{fact} is $have)";
}

# ---------------------------------------------------------------------------
# Facts
# ---------------------------------------------------------------------------

=method facts_for

    my $facts = $executor->facts_for($step);
    # { board_actionable => 'yes', ticket_status => 'todo',
    #   ticket_blocked => 'no', ticket_claimed => '' }

Measures the facts a step's precheck may ask about, off the board the step names
-- which is why it lives here and not in the store: reading a board is
execution. See L</Who measures the facts> for the vocabulary and for why an
unmeasurable fact is left out rather than defaulted.

C<ticket_claimed> is the claim name as the card carries it, not whether that
claim is still live: whether a claim has expired is C<karr pick>'s question
(L<App::karr::Role::PickRules>) and answering it differently here would be a
second opinion about the same card.

=cut

sub facts_for {
  my ( $self, $step ) = @_;
  my $repo = $step->{repo};
  return {} unless defined $repo && length $repo;
  return {} unless App::karr::Git->new( dir => "$repo" )->is_repo;

  my $f = $self->foundation;
  my %states = try { $f->_task_states( $repo ) } catch { () };

  my %facts = ( board_actionable =>
    ( grep { $f->_is_actionable( $states{$_} ) } keys %states ) ? 'yes' : 'no' );

  if ( defined $step->{ticket} ) {
    my $card = $states{ $step->{ticket} };
    if ( $card ) {
      $facts{ticket_status}  = $card->{status} // '';
      $facts{ticket_blocked} = $card->{blocked} ? 'yes' : 'no';
      $facts{ticket_claimed} = defined $card->{claimed_by} ? $card->{claimed_by} : '';
    }
  }
  return \%facts;
}

# ---------------------------------------------------------------------------
# Transport
# ---------------------------------------------------------------------------

# The fleet namespace, in. A failure is fatal to the tick rather than a
# warning: see L</Pull before reading, push before working>.
sub _pull {
  my ( $self ) = @_;
  my $ok = try {
    $self->store->git->pull_foundation;
  } catch {
    warn 'karr-foundation: pull of refs/karr-foundation/ failed: '
       . clean_error($_) . "\n";
    0;
  };
  warn "karr-foundation: refusing to execute the chain without a fresh view "
     . "of refs/karr-foundation/ \x{2014} two machines would run the same step\n"
    unless $ok;
  return $ok ? 1 : 0;
}

# The fleet namespace, out.
sub _push {
  my ( $self ) = @_;
  my $ok = try {
    $self->store->git->push_foundation;
  } catch {
    warn 'karr-foundation: push of refs/karr-foundation/ failed: '
       . clean_error($_) . "\n";
    0;
  };
  return $ok ? 1 : 0;
}

# The step's own board, so its precheck is measured against the fleet's view of
# it and not against this clone's last fetch. The ticket-mode path pulls again
# on its way in, which is one fetch more than strictly needed and the cheaper
# half of the trade: the alternative is a precheck decided on stale refs.
sub _pull_board {
  my ( $self, $repo ) = @_;
  return try {
    $self->foundation->_sync_pull( $repo );
    1;
  } catch {
    warn "karr-foundation: pull error in $repo: " . clean_error($_) . "\n";
    0;
  };
}

1;
