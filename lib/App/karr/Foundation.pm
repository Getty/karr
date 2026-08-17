# ABSTRACT: Single-shot foundation daemon — periodic agent execution across karr boards

package App::karr::Foundation;
our $VERSION = '0.501';
use Moo;
use MooX::Options (
  usage_string => 'USAGE: karr-foundation [options]',
);
use App::karr::Error qw( user_error );
use Path::Tiny;
use POSIX qw( SIGTERM SIGINT SIGHUP );
use YAML::XS ();
use Time::Piece;
use Digest::MD5 qw( md5_hex );
use Try::Tiny;
use App::karr::Git;
use App::karr::BoardStore;
use App::karr::ActivityLog;
use App::karr::Foundation::Runner;
use App::karr::Foundation::State;
use App::karr::Foundation::Overview;
use App::karr::Foundation::Picker;
use App::karr::Foundation::Agents;

# Instruction handed to a synthesized agent command via the $PROMPT variable
# when neither the .karr file nor the config overrides it.
our $DEFAULT_PROMPT =
    'Use the karr-coordinator skill: pick the next actionable task on this '
  . 'board, complete it, and move it forward. If you cannot proceed, block '
  . 'the task with a reason.';

# The same, for a ticket-mode run. It cannot be $DEFAULT_PROMPT: that one opens
# by telling the agent to pick its own work, which is the one thing a run that
# has already been given a card must not do.
our $DEFAULT_TICKET_PROMPT =
    'Use the karr-coordinator skill: work on the one task named below, '
  . 'complete it, and move it forward. If you cannot proceed, block the task '
  . 'with a reason.';

# Appended to whatever prompt was resolved, ticket id spliced in by foundation
# itself. It has to be foundation that splices: the prompt reaches the agent as
# $PROMPT and /bin/sh does not rescan an expanded value, so a prompt writing
# $KARR_TASK would hand the agent those ten characters (#159). Last, not first,
# because it has to win over an operator prompt that says "pick the next task".
our $TICKET_ASSIGNMENT =
    'The task for this run is #%s: work on that one task and no other. Claim '
  . 'it before you start, and stop when it is done, handed off or blocked. Do '
  . 'not pick up another task.';

option config => (
  is     => 'ro',
  format => 's',
  doc    => 'Path to config file (default: ~/.config/karr-foundation/config.yml)',
);

option command => (
  is     => 'ro',
  format => 's',
  doc    => 'Global agent command; overrides .karr file per-repo',
);

option force => (
  is  => 'ro',
  doc => 'Run agent even if no board change detected and no open tasks',
);

option dry_run => (
  is  => 'ro',
  doc => 'Print what would run without executing',
);

option verbose => (
  is  => 'ro',
  doc => 'Extra output',
);

option status => (
  is  => 'ro',
  doc => 'Print a read-only overview of every board and exit (no agent runs)',
);

has _stream_to_terminal => (
  is      => 'lazy',
  builder => sub { -t STDOUT || $_[0]->verbose },
);

# The config file this run reads, whether or not it exists. Its own attribute
# because it is more than the source of _config_data: the per-machine agent
# availability lives beside it (App::karr::Foundation::Agents), so --config
# relocates that too.
has _config_path => (
  is      => 'lazy',
  builder => '_build_config_path',
);

sub _build_config_path {
  my ( $self ) = @_;
  return defined $self->config
    ? path( $self->config )
    : path( $ENV{HOME} )->child( '.config', 'karr-foundation', 'config.yml' );
}

has _config_data => (
  is      => 'lazy',
  builder => '_build_config_data',
);

sub _build_config_data {
  my ( $self ) = @_;
  my $cfg_path = $self->_config_path;

  unless ( $cfg_path->exists ) {
    warn "karr-foundation: config not found at $cfg_path \x{2014} nothing to do\n";
    return {};
  }

  # Both of these are "your config is wrong", not "karr is wrong", so neither
  # gets a Carp call site pointing into this file (#77). YAML::XS's own error
  # names the document, line and column and carries no call site of its own, so
  # it goes through whole rather than through clean_error, which would keep
  # only its "YAML::XS::Load Error: The problem:" header.
  my $data = try {
    YAML::XS::LoadFile("$cfg_path");
  } catch {
    user_error("Cannot parse config $cfg_path: $_");
  };
  user_error("Config must be a YAML mapping") unless ref $data eq 'HASH';
  return $data;
}

# Collaborators split out of this module along its natural seams (see the
# App::karr::Foundation::* classes). Each holds a weak back-reference to this
# foundation for shared options/helpers; delegation keeps the historical
# method names callable directly on the foundation object.

has _runner => (
  is      => 'lazy',
  handles => [qw(
    _run_command _error_patterns _match_error
    _run_result _result_error _result_summary _result_line
  )],
);

sub _build__runner {
  my ( $self ) = @_;
  return App::karr::Foundation::Runner->new( foundation => $self );
}

has _state => (
  is      => 'lazy',
  handles => [qw(
    _lock_held _acquire_lock _release_lock _force_release_lock
    _read_lock_metadata
    _state_get _state_set _state_del
    _cooldown_active _set_cooldown _clear_cooldown
    _bump_attempts _reset_attempts
  )],
);

sub _build__state {
  my ( $self ) = @_;
  return App::karr::Foundation::State->new( foundation => $self );
}

has _agents => (
  is => 'lazy',
);

sub _build__agents {
  my ( $self ) = @_;
  return App::karr::Foundation::Agents->new( foundation => $self );
}

has _overview => (
  is      => 'lazy',
  handles => [qw( _print_overview )],
);

sub _build__overview {
  my ( $self ) = @_;
  return App::karr::Foundation::Overview->new( foundation => $self );
}

# Open file descriptors that hold flock(2) locks on .karr.lock files for the
# boards currently being drained. The fd is what keeps the lock — closing it
# would drop the flock immediately, so Foundation keeps it for the lifetime
# of the drain. _keep_lock_fh / _take_lock_fh are the only writers/readers.
has _lock_fhs => (
  is      => 'ro',
  default => sub { {} },
);

# The agent process this run currently has on the board: { repo, pid, pgid,
# lockfile }. Set by the runner immediately after fork, cleared by the drain
# after waitpid. The SIGTERM handler in run() reads it to know what to kill.
# Undef between agents — the handler is a no-op on those gaps.
has _live_agent => (
  is      => 'rw',
  default => sub { undef },
);

# fd stash accessors used by State.pm — kept private to the foundation/state
# pair because they leak the internal "lock = open fd" model. Nobody else
# should care.
sub _keep_lock_fh {
  my ( $self, $repo, $fh ) = @_;
  $self->_lock_fhs->{ "$repo" } = $fh;
  return;
}

sub _take_lock_fh {
  my ( $self, $repo ) = @_;
  my $key = "$repo";
  my $fh  = delete $self->_lock_fhs->{$key};
  return $fh;
}

=synopsis

    # Typical cron entry — run every 5 minutes
    */5 * * * * /path/to/karr-foundation

    # Force a run regardless of board state
    karr-foundation --force

    # Preview what would run
    karr-foundation --dry-run --verbose

    # Read-only overview of every board (no agent runs)
    karr-foundation --status

=description

F<karr-foundation> is a single-shot, idempotent CLI meant to be invoked
periodically (cron, systemd-timer, while-loop). It scans configured karr
boards, detects changes or open work, and B<drains> each board by invoking the
configured agent command repeatedly until no actionable task remains.

B<Config file:> C<~/.config/karr-foundation/config.yml> (or C<--config>).

  dirs:
    - /path/to/repo1
    - /path/to/repo2

  scan:
    - /path/to/parent-dir   # finds all direct subdirs that have a .karr file

B<Per-repo .karr file:>

  claude: true              # synthesize the canonical claude command (opt-in)
  claude_bin: claude        # binary for claude: true (default: claude)
  claude_max_turns: 30      # --max-turns for claude: true (default: 30)
  claude_permission_mode: bypassPermissions   # (default: bypassPermissions)
  prompt: >-                # agent instruction, exposed as $PROMPT
    Use the karr-coordinator skill: pick the next actionable task and move it.
  command: claude -p "$PROMPT"   # explicit command; wins over claude: true
  on_idle: skip             # 'skip' (default) | 'always-run'
  max_runtime: 1800         # seconds: per-command SIGKILL (0 = no limit)
  mode: drain               # drain (default) | single | ticket
  drain: true               # older spelling of mode: true=drain, false=single
  max_attempts: 2           # stalls on one task before auto-block (default: 2)
  max_iterations: 50        # hard cap on drain iterations (default: 50)
  cooldown_base: 1          # cooldown minutes at level 0 (default: 1)
  cooldown_max: 64          # cooldown ceiling in minutes (default: 64)
  error_patterns:           # extra case-insensitive substrings → common-error
    - my custom api error   # (added to the defaults; matched as written)

  agent: minimax            # a named agent from the config's 'agents:' section

C<claude>, C<claude_bin>, C<claude_max_turns>, C<claude_permission_mode>,
C<command>, C<mode> and C<prompt>/C<default_prompt> may also be set globally in
the config file; the per-repo F<.karr> value wins.

B<Named agents.> A board has one C<command>. A fleet has several agent commands
with different strengths and different failure modes, so the config can name
them and a board can pick one:

  agents:
    minimax:
      command: claude_with_minimax
      kind: claude-code       # the invocation contract; default: shell
      probe_every: 15m        # optional -- see "Agent availability" below
      permission_mode: bypassPermissions    # kind: claude-code only
      max_turns: 30                         #   "     "        "
      allowed_tools: [ Bash, Edit ]         #   "     "        "
      description: >-
        Prose. What this agent is good at, where it is weak, what it costs.

  default_agent: minimax    # for boards whose .karr names none
  probe_every: 10m          # fleet-wide default for agents that name none

C<description> is never read by karr. It is carried for the agent that routes
work across the fleet: the thing choosing is a language model, and it reads
prose better than it matches taxonomies, so there are no classes and no enums
here. C<karr-foundation --status --verbose> prints it.

Agent definitions are B<local and only local>. They are not board state and
never sync: an agent command that exists on one machine does not exist on the
next, and an account limit is a property of a person, not of a project.

C<agent:> resolves below the literal command strings and above C<< claude:
true >> -- the full order is C<--command>, C<default_command>, the F<.karr>
C<command>, the F<.karr> C<agent>, C<default_agent>, C<< claude: true >>. A
board that names an agent the config does not define is an error that skips
B<that board>, not one that silently stops running.

B<Invocation contracts.> C<kind> says what karr may append to a definition's
C<command>:

=over 4

=item * C<shell> (the default) - the command is a complete shell template and
karr appends B<nothing>. This is what a F<.karr> C<command> has always been:
karr cannot know what the thing at the other end understands.

=item * C<claude-code> - karr appends C<-p "$PROMPT">, an output format, and
C<--permission-mode>, C<--max-turns> and C<--allowed-tools> from the
definition. Permission escalation is therefore a property of the agent
definition rather than something baked into a wrapper script.

=back

The output format is C<stream-json --verbose --include-partial-messages>, not
plain C<json>, and that is the one deliberate choice in this contract. karr
needs the run's own report (see "The run's own report" below), which only a
structured format emits -- but plain C<json> prints B<nothing at all> until the
run ends, which would silently cancel the live output promised under "Live
output" below on exactly the runs that take half an hour. C<stream-json> ends
with the same result object and streams on the way, so
L<App::karr::Foundation::Runner> renders the assistant's text out of it for the
terminal and F<.karr.log> while the raw stream is what the run is classified
from. The ticket of a C<< mode: ticket >> run is B<not> appended: claude-code
has no flag for it, so the id keeps travelling as a closing sentence in
C<$PROMPT> and as C<$KARR_TASK>.

B<Agent availability.> karr keeps the least it can per named agent: C<ok>, or
C<failing> since a moment with a next attempt due at another. No cost, no
tokens, no quotas -- a rate limit and an exhausted budget look identical from
the outside (the command stops working), so B<one> mechanism covers both, and
every other reason a command can stop working comes along for free.

A drain that ends in a C<common-error> marks its agent failing; any other
outcome says it works. While an agent is failing, B<every> board that uses it
is skipped -- the fact is about the command and the machine, not about a
repository, so two boards on one agent share the outage instead of each burning
a window rediscovering it. That is a level above the per-board cooldown, which
keeps working exactly as before underneath it. Like the cooldown, C<--force>
does not override it; the wait is bounded by C<probe_every> and ends by itself.

When the next attempt comes round the agent is simply run again on the work
that was waiting: the probe B<is> the run. Where the reset rhythm is known it
is configured as C<probe_every>; where it is not, the retry is at a fixed
interval and every recovery is B<recorded> -- from when it broke to when it
worked again, with what it looked like. Reading a pattern out of those records
is the coordination agent's job, never a learning algorithm inside karr.

The record lives beside the config file that defines the agents
(F<agents.state> next to F<config.yml>, so C<--config> relocates it), because
it belongs to neither of the two obvious places: F<.karr.state> is per
repository and this is not, and the board's own config syncs, which would push
one person's spent limit at everybody else's fleet.

B<Run mode.> C<mode> says what one pass over a repo is:

=over 4

=item * C<drain> (the default) - run the agent again and again until the board
stops moving. This is what F<karr-foundation> has always done and what
"Drain semantics" below describes.

=item * C<single> - exactly one agent run; the agent still chooses its own work.

=item * C<ticket> - exactly one agent run, about B<one card foundation names>.

=back

C<< drain: true|false >> is the older spelling of the first two and stays
honoured: C<true> means C<drain>, C<false> means C<single>. Two keys that both
meant "one run" would be a trap, so they are one key with an alias rather than
two switches -- C<mode> is asked first, C<drain> answers only when C<mode> is
absent, and a per-repo C<drain> still beats a config-wide C<mode>. An
unrecognised C<mode> is an error that skips the repo, never a silent fallback
to draining it.

B<Ticket mode.> Before the agent starts, foundation picks the card the run is
about -- L<App::karr::Foundation::Picker>, applying C<karr pick>'s eligibility
and ranking (not terminal, not blocked, not held by a live claim; class, then
priority, then id). It is told to the agent twice: spliced into C<$PROMPT> as a
closing sentence naming the id, and exported as C<$KARR_TASK> for a command
template that wants the bare number. Nothing is appended to the command itself
-- how arguments are appended belongs to the per-agent contract (C<kind:>),
which is a separate piece of work, and an environment variable works with every
template that exists today.

Foundation names the card; it does B<not> claim it. The claim is the agent's
work session, minted with C<karr agentname> and reused across its own C<move>
and C<handoff> (#176), and the board's per-repo lock plus the one-agent-per-
repository rule already keep anybody else off the card for the length of the
run. So an agent that dies mid-work leaves at most its own claim -- released by
C<claim_timeout>, or by C<karr unlock> for a pick lock -- and costs one attempt
on foundation's counter.

The run is then judged by that card and not by the board hash: C<progress> when
it moved (status, claim or C<updated> changed, or it left the actionable set),
C<stall> when it did not, whatever else on the board did move. A stall bumps
the card's attempt counter and auto-blocks it at C<max_attempts>, under the same
ownership guard as a drain -- a card somebody else took during the run is never
blocked on foundation's say-so. With no assignable card at all, ticket mode runs
B<no agent>, logs C<TICKET none assignable>, and returns C<idle>; C<--force> and
C<< on_idle: always-run >> force the check, not a run without a card.

B<Board-level disable.> A board can opt out of automated agent runs in its own
karr state — C<foundation.enabled> in C<refs/karr/config>, set with
C<karr disable [--reason "why"]> and cleared with C<karr enable>. Because the
flag is board state it syncs with the board, so every foundation instance on
every machine honours it. A disabled board is skipped B<whole>: the flag is
checked before the agent command is resolved and before the drain decision, so
there is no drain, no auto-block and no agent run. It therefore wins over
C<--command>, the config's C<default_command>, the F<.karr> C<command> and
C<< claude: true >>, and C<--force> does B<not> override it. Use it for a
repository whose backlog is parked (an abandoned project kept for reference)
that a globally configured C<default_command> would otherwise drain. C<--status>
shows such a board with a C<disabled> flag and its reason.

B<Coordinator and overview.> Agent execution is opt-in — a board runs an agent
only via C<command>, a named C<agent> or C<< claude: true >>. When B<no> board
has an agent configured, the default action is a read-only B<overview> of every
board (status counts, in-progress/blocked tasks, lock and cooldown state, which
agent a board uses and whether it currently works); a human can use foundation
purely to coordinate their own work. C<--status> forces the overview regardless
of configuration.

B<Live output.> When run interactively (TTY) or with C<--verbose>, the agent's
output is streamed to the terminal in real time as foundation reads it; it is
always appended to F<.karr.log> regardless of TTY. To shape what is shown, the
command may emit stream-json and filter it, e.g.:

  command: >-
    claude -p "$PROMPT"
      --output-format stream-json --verbose --include-partial-messages
      --permission-mode bypassPermissions --max-turns 10
    2>&1 | jq -r 'select(.type == "stream_event") | .event.delta.text // empty'

Set C<max_runtime: 0> in F<.karr> to disable the per-run timeout entirely
(agent runs until completion with no SIGKILL).

B<Drain semantics.> Each iteration runs C<command> once, then classifies the
result from what foundation can observe — the run's own report where it made
one, otherwise the exit code, board ref movement, and the run's captured
output:

=over 4

=item * B<progress> — the board changed; keep draining.

=item * B<stall> — a task B<this run's agent engaged> did not move. That task's
attempt counter is bumped; at C<max_attempts> it is auto-blocked
(C<blocked: auto-block: no progress after N attempts (foundation)>) so it drops
out of the actionable set and the drain can finish. The agent may always set a
better reason itself with C<karr edit --block>; the auto-block is a fallback.

B<Engaged> means foundation can prove the agent worked on that card during
B<this> drain: the agent runs with C<KARR_ROLE=agent>, so every C<karr> write
it makes is recorded in the board's own activity log under the C<agent>
identity, and only the tasks named there — held by nobody, or by a claim name
the agent itself wrote under — can be penalized. A card somebody else holds is
never touched, and neither is one the agent merely left claimed in an earlier
run: a stale claim is what C<claim_timeout> and C<karr unlock> are for. Where
that evidence is missing altogether — an agent that does not write through
C<karr>, an unreadable log — foundation auto-blocks B<nothing> rather than
guess: the drain then simply ends on its iteration cap, which is far cheaper
than blocking a human's in-progress card out from under them (#158).

=item * B<common-error> — a non-zero/timeout exit, or an error pattern in the
output of a run that moved B<nothing> (rate limit, auth, network, 5xx, …). No
task is penalized; the repo enters an exponential cooldown (C<cooldown_base> ×
2^level minutes, capped at C<cooldown_max>, reset on the next clean run) and is
skipped until it expires.

What the run did is asked before what it printed: a run that exited 0 and moved
the board is progress whatever text scrolled past, and is never reclassified by
its own transcript. The scan is evidence only where there is no other — a run
that produced no board movement at all, which is what a rate-limited or
unauthenticated agent looks like. A pattern seen in a run that B<did> move the
board is noted in F<.karr.log> and otherwise ignored.

The default patterns are correspondingly narrow: a symptom word counts next to
a failure word on the same line ("network error", "invalid credentials",
"quota exceeded"), not on its own, and an HTTP status counts only where
something adjacent marks it as one ("API error: 429", "429 Too Many Requests"),
not in a diffstat or a line number. Before this, an agent that printed its own
board tripped the scan on a backlog title, and a diffstat of 403 changed lines
tripped it on C<403> (#160).

=item * B<idle> — the agent did nothing and grabbed nothing; stop.

=back

B<The run's own report.> An agent invoked with C<--output-format json> ends its
output with one line: a JSON object saying whether the run failed, how it
ended, how many turns it took, how long it ran and what it cost. Where a run
leaves one, foundation classifies from it and the text scan below does not run
at all.

Foundation is not configured for this and does not inspect the command string
for it — it reads the tail of the output, because that is where the format puts
its result and nothing else has to be kept in step with anything. Only the
B<last> non-empty line counts: prose before the object is irrelevant, prose
containing one cannot be mistaken for it (an agent printing a board can print a
pasted result object the same way #160's board printed a C<503>), and anything
after it makes the run unstructured again, so the scan takes over. The
reasoning is written out at C<_run_result> in L<App::karr::Foundation::Runner>.

A reported error ranks with the exit code, not with the scan: it is the run's
statement about itself, not an inference drawn from its prose, so the
"what it did before what it printed" guard below does not apply to it. Its
B<kind> decides what happens next. A provider status (C<api_error_status>) is
the case the scan was written for and backs the board off as a rate limit
always did. A spent turn budget (C<error_max_turns>) is not: the agent worked,
the provider answered, and the task was simply larger than the budget it was
given — so it is logged, the board is not parked, and the run is judged by what
it moved. Any other reported error keeps its own name (C<error_during_execution>)
and cools the board down. A non-zero exit a report of B<success> does not
account for is still a common error: the report is the agent's, the exit code
may be its wrapper's.

In ticket mode the report is what finally separates the two stalls that used to
look identical — "the agent reports it could not proceed" and "the agent did
nothing" — and F<.karr.log> names which one it was
(C<STALL task#N — the agent ran out of turns>). With no report it says exactly
that rather than guessing.

All per-board state files are gitignored: C<.karr.state> (board hash, per-task
attempts, cooldown, last error, last report), C<.karr.lock>, C<.karr.log>.
Agent availability is not among them: it is not per board and does not live in
the repository at all (see "Agent availability" above). C<last_error>
describes the B<last> run and is removed again by the next run that is not a
common error, so it never outlives the cooldown it caused. C<last_result> is
the same for the report — how the last run ended, its turns, duration and cost
— and is dropped again by a run that reported nothing.

=cut

# ---------------------------------------------------------------------------
# Public
# ---------------------------------------------------------------------------

sub run {
  my ( $self ) = @_;
  my @repos = $self->_discover_repos;
  unless ( @repos ) {
    warn "karr-foundation: no repos found \x{2014} check config\n";
    return 1;
  }

  # --status forces the read-only overview regardless of agent config.
  if ( $self->status ) {
    $self->_print_overview( \@repos );
    return 0;
  }

  # foundation is a multi-board coordinator: agent execution is opt-in. When no
  # board has an agent configured, the default action is the overview — a human
  # can use foundation purely to see what is happening across boards. A board
  # disabled in its own karr state never counts as an agent board here either,
  # so a config of nothing but disabled boards falls back to the overview.
  # A board naming an agent that is not defined raises out of _agent_command.
  # That is a per-board configuration error and _process_repo is where it gets
  # reported (run() catches it there and skips one board); here it must not
  # decide the whole run's shape, so it counts as "an agent was meant to run".
  my $any_agent = grep {
    my $repo = $_;
    !$self->_board_disabled( $repo )
      && try { defined $self->_agent_command( $repo, $self->_load_karr($repo) ) }
         catch { 1 };
  } @repos;
  unless ( $any_agent ) {
    print "No agent will run on any board. Showing overview "
        . "(set 'command:', 'agent:' or 'claude: true' in a .karr file to "
        . "enable agents; a board disabled with 'karr disable' never runs "
        . "one).\n\n";
    $self->_print_overview( \@repos );
    return 0;
  }

  # SIGTERM/SIGINT/SIGHUP mid-drain used to leave the agent reparented to init
  # and the .karr.lock naming a dead pid, and the next cron tick read the dead
  # pid as free and started a second agent on the same board (#163, #148).
  # The handler kills the agent's process group, releases the lock, and exits
  # non-zero — the same exit shape systemd/cron see on any other failure, so
  # the operator's monitoring does not need a special case for "killed cleanly
  # mid-drain". Installed for the lifetime of run() and restored to default on
  # the way out so a stray post-run signal goes to the OS, not back into us.
  $self->_install_signal_handlers;

  for my $repo ( @repos ) {
    try {
      $self->_process_repo( $repo );
    } catch {
      warn "karr-foundation: error in $repo: $_\n";
    };
  }

  $self->_restore_default_signal_handlers;
  return 0;
}

# SIGTERM/INT/HUP handler: kill the live agent's process group, release the
# lock, exit non-zero. Built once at run() time and shared by all three
# signals — the OS's default for SIGINT/SIGHUP is exit too, but those do not
# wait for the agent to die, which is the whole problem.
sub _install_signal_handlers {
  my ( $self ) = @_;
  my $handler = sub { $self->_handle_shutdown_signal(@_); };
  $SIG{TERM} = $handler;
  $SIG{INT}  = $handler;
  $SIG{HUP}  = $handler;
  return;
}

sub _restore_default_signal_handlers {
  $SIG{TERM} = 'DEFAULT';
  $SIG{INT}  = 'DEFAULT';
  $SIG{HUP}  = 'DEFAULT';
  return;
}

# Signal handler body. Perl signal handlers run in a restricted context — no
# malloc, no PerlIO ops beyond safe ones, and certainly no $self->method on an
# object whose class might be in the middle of compilation. Foundation is
# already running and the methods called here are simple attribute reads and
# POSIX ops, which are documented as safe in 5.16+. We do NOT call
# Foundation's own _append_log or anything that opens files — the agent is
# dying and the lock is going away; the operator gets the next run's log.
sub _handle_shutdown_signal {
  my ( $self, $sig_name ) = @_;
  my $agent = $self->_live_agent;
  if ( $agent && $agent->{pgid} ) {
    # Negative pid = process group (kill(2) group semantics). The agent's
    # pgid is the agent's own pid because Runner calls setpgrp(0,0) in the
    # child right after fork, so kill 'TERM', -$pgid signals the whole group
    # — including any grandchildren the agent itself forked (#148).
    kill 'TERM', -$agent->{pgid};
    # Give the group a moment to die. SIGTERM is catchable; a hung child
    # needs SIGKILL. Two seconds matches the timeout path in Runner.
    my $end = time + 2;
    while ( time < $end ) {
      last if kill( 0, $agent->{pid} ) == 0;
      select undef, undef, undef, 0.05;
    }
    kill 'KILL', -$agent->{pgid};
    # Reap without blocking — the SIGKILL will deliver but the actual wait
    # is best-effort because we are already on the way out.
    waitpid $agent->{pid}, 0 if $agent->{pid};
  }
  if ( $agent && $agent->{repo} ) {
    # Force-release the lock: we may have lost the fd through a process
    # restart, but the recorded pid in the file still matches $$ if this is
    # the foundation that took it. _force_release_lock verifies and unlinks.
    # Wrap the repo argument in path() in case it crossed a string boundary
    # (some callers keep agent->{repo} as a string); State.pm's helpers all
    # take a Path::Tiny object.
    $self->_force_release_lock( path( $agent->{repo} ) );
  }
  # Restore defaults so the second delivery (e.g. impatient operator) kills us
  # for real instead of looping in the handler.
  $self->_restore_default_signal_handlers;
  # Exit non-zero so cron/systemd can see we did not finish a clean run.
  # $sig_name is "TERM" / "INT" / "HUP" — 128 + signal number is the
  # conventional shell exit code for signal death.
  my $sig_num = $sig_name eq 'TERM' ? SIGTERM
              : $sig_name eq 'INT'  ? SIGINT
              : $sig_name eq 'HUP'  ? SIGHUP
              : 15;
  POSIX::_exit( 128 + $sig_num );
}

=method run

    exit App::karr::Foundation->new_with_options->run;

The single entry point, invoked by F<bin/karr-foundation>. One pass over
every configured repo, then returns -- there is no internal loop; running
periodically is left to cron/systemd-timer/an external C<while> loop, per
L</DESCRIPTION>. Returns C<1> (a process exit code, not an exception) when
C<_discover_repos> finds nothing at all -- an empty C<dirs>/C<scan> in the
config, or a config file that does not exist -- and C<0> otherwise, including
when individual repos error out: a repo whose C<_process_repo> dies is
C<warn>ed and skipped, never propagated, so one broken board cannot stop the
rest of the run.

With C<--status> it prints L<App::karr::Foundation::Overview>'s read-only
overview and returns without touching any board. Without it, C<run> first
checks whether B<any> repo has an agent configured at all (per repo,
C<_agent_command>, excluding boards disabled via C<karr disable>); if none
do, it falls back to the same overview instead of doing nothing, since
agent execution is opt-in and a config with no agents configured is a
legitimate way to use foundation purely as a status board. Otherwise it calls
C<_process_repo> for each repo in turn, which is what applies the disable
flag, the lock, the cooldown, the change/actionability check, and finally the
drain loop described under "Drain semantics" above.

=cut

# ---------------------------------------------------------------------------
# Discovery
# ---------------------------------------------------------------------------

sub _discover_repos {
  my ( $self ) = @_;
  my @repos;

  # Explicit repo roots
  for my $dir ( @{ $self->_config_data->{dirs} // [] } ) {
    my $p = path( $dir );
    if ( $p->is_dir ) {
      push @repos, $p;
    } else {
      warn "karr-foundation: dir not found: $dir\n";
    }
  }

  # Scanned parent directories — check direct children for .karr file
  # OR refs/karr/config (karr-init'd repo without .karr file)
  for my $scan_dir ( @{ $self->_config_data->{scan} // [] } ) {
    my $p = path( $scan_dir );
    unless ( $p->is_dir ) {
      warn "karr-foundation: scan dir not found: $scan_dir\n";
      next;
    }
    for my $child ( $p->children ) {
      next unless $child->is_dir;
      # .karr file takes precedence; also detect karr-init'd repos
      if ( $child->child('.karr')->exists ) {
        push @repos, $child;
      } elsif ( $self->_is_karr_board_root( $child ) ) {
        push @repos, $child;
      }
    }
  }

  # A repo reachable through both dirs: (explicit) and scan: (its parent) was
  # processed twice per tick — the agent ran twice and the overview printed
  # the board twice (#166). The two Path::Tiny objects can be the same string,
  # differ only by trailing slash, or even be a symlink and its target; the
  # key is the canonical filesystem path. First-seen wins so the explicit
  # dirs: order is preserved over whatever order scan: happened to find them.
  my %seen;
  my @uniq;
  for my $repo ( @repos ) {
    my $key = try { $repo->realpath } catch { $repo->absolute };
    next if $seen{$key}++;
    push @uniq, $repo;
  }
  return @uniq;
}

# True when $dir is *itself* the root of a karr-init'd repo — resolves via
# libgit2 so packed refs (git gc / pack-refs) and worktree gitdir indirection
# are handled, unlike a bare .git/refs/karr/config file check. libgit2's
# open_ext walks up to find an enclosing .git, so a plain directory nested
# inside a karr repo would spuriously match; guard by confirming the resolved
# repo root is $dir, not an ancestor.
sub _is_karr_board_root {
  my ( $self, $dir ) = @_;
  my $git = App::karr::Git->new( dir => "$dir" );
  return 0 unless $git->is_repo;
  my $root = $git->repo_root or return 0;
  return 0 unless $root->realpath eq path( $dir )->realpath;
  return $git->ref_exists('refs/karr/config');
}

# ---------------------------------------------------------------------------
# Per-repo processing
# ---------------------------------------------------------------------------

sub _process_repo {
  my ( $self, $repo ) = @_;

  # Check if repo has karr board (either .karr file or karr refs). Resolve the
  # ref via libgit2 so packed refs and worktrees are handled — $repo is an
  # already-known repo root here, so open_ext's walk-up cannot false-match.
  my $has_karr = $repo->child('.karr')->exists
              || App::karr::Git->new( dir => "$repo" )->ref_exists('refs/karr/config');
  unless ( $has_karr ) {
    $self->_say_verbose("skip $repo \x{2014} no karr board");
    return;
  }

  # Board-level disable flag, checked FIRST: before the agent command is even
  # resolved and before the drain decision. A disabled board is skipped whole —
  # no drain, no auto-block, no agent run — so the flag wins over --command,
  # the config's default_command, the .karr command and 'claude: true'. It is
  # deliberately absolute: --force does not override it.
  return if $self->_skip_disabled( $repo );

  my $karr = $self->_load_karr( $repo );

  # Resolve the agent command (CLI > default_command > .karr command > a named
  # agent definition > claude: true synthesis). Agent execution is opt-in: a
  # board with no agent is shown in the overview, not run.
  my ( $cmd, $agent ) = $self->_resolve_agent( $repo, $karr );
  unless ( defined $cmd ) {
    $self->_say_verbose("skip $repo \x{2014} no agent configured (see --status)");
    return;
  }

  # Check lock — skip if another instance is running
  if ( $self->_lock_held( $repo ) ) {
    $self->_say_verbose("skip $repo \x{2014} locked by running agent");
    return;
  }

  # Respect exponential cooldown left by a previous common-error run
  if ( $self->_cooldown_active( $repo ) ) {
    my $until = $self->_state_get( $repo, 'cooldown_until' ) // 0;
    $self->_say_verbose( "skip $repo \x{2014} in cooldown for " . ( $until - time ) . "s" );
    return;
  }

  # And the agent's own availability, which is the same idea one level up. The
  # cooldown above parks THIS BOARD after a bad run; this parks EVERY board
  # that uses the agent that had it, because "the command stopped working" is a
  # fact about the command and the machine, not about the repository. Two repos
  # driven by the same agent share the outage instead of each burning a window
  # discovering it. Like the cooldown, --force does not override it: the wait
  # is bounded by probe_every and ends by itself.
  if ( $agent && !$self->_agents->available( $agent->{name} ) ) {
    my $av   = $self->_agents->availability( $agent->{name} );
    my $wait = ( $av->{next_attempt} // 0 ) - time;
    $self->_say_verbose( "skip $repo \x{2014} agent '$agent->{name}' failing"
      . ( defined $av->{last_error} ? " ($av->{last_error})" : '' )
      . ", next attempt in ${wait}s" );
    return;
  }

  # Pull latest refs. A pull that refuses -- the wholesale-wipe guard, the
  # board-identity guard, and (since #154) the unapplied-refs guard all die
  # rather than return false -- must not abort the drain loop. The other
  # per-repo step that can die (_drain_repo below) is wrapped in its own
  # try and turned into a structured error result; the pull sits at the same
  # level and is isolated the same way, so a refusal from one board warns
  # and is skipped here while the rest of run() continues to the next.
  # The pull happens before the lock is taken, so "release whatever it
  # holds" is a no-op today; the wrap is for the structural isolation
  # (clean separation, karr-shaped error message) and is forward-compatible
  # with any future caller that takes the lock before pulling.
  my $pull_ok = try {
    $self->_sync_pull( $repo );
    1;
  } catch {
    warn "karr-foundation: pull error in $repo: $_\n";
    0;
  };
  return unless $pull_ok;

  # The pull may have just brought the disable flag in from another machine —
  # re-check before committing to a drain, so a board disabled elsewhere is
  # never drained even once by this host.
  return if $self->_skip_disabled( $repo );

  # Decide whether to start a drain at all
  my $should_run = $self->force;
  unless ( $should_run ) {
    my $prev_hash = $self->_state_get( $repo, 'hash' ) // '';
    my $curr_hash = $self->_ref_hash( $repo ) // '';
    my $on_idle   = $karr->{on_idle} // 'skip';
    $should_run = ( $curr_hash ne $prev_hash )
               || $self->_has_actionable_tasks( $repo )
               || ( $on_idle eq 'always-run' );
  }

  unless ( $should_run ) {
    $self->_say_verbose("skip $repo \x{2014} no board change and no actionable tasks");
    return;
  }

  # Acquire lock — flock-based now, so two ticks that overlap race on the
  # file rather than on a check-then-act gap a git pull apart (#162). Failure
  # here means another foundation instance holds the board; we skip and move
  # on instead of spewing over the existing lock.
  unless ( $self->_acquire_lock( $repo ) ) {
    $self->_say_verbose("skip $repo \x{2014} lock contended (another tick holds it)");
    return;
  }
  my $result = try {
    $self->_drain_repo( $repo, $karr, $cmd, $agent );
  } catch {
    warn "karr-foundation: drain error in $repo: $_\n";
    { outcome => 'error', exit => 1 };
  };
  $self->_release_lock( $repo );

  # Exponential cooldown bookkeeping: grow on common-error, reset otherwise.
  # A run that was not a common error also drops last_error — it describes the
  # last run, and one left standing outlives the cooldown it caused and reads
  # as a contradiction against the last_exit written just below (#160).
  #
  # The same verdict updates the named agent's availability, for boards that
  # use one. Nothing finer is asked of it: a rate limit, a spent budget, a
  # revoked key and a wrapper that is not installed here all arrive as
  # common-error, and the same bounded retry answers all of them. A run that
  # was NOT a common error says the command works, which is what ends an
  # outage and gets the moment it ended written down. A false positive costs
  # one probe interval of caution; a false negative costs every board on that
  # agent its next window.
  if ( ( $result->{outcome} // '' ) eq 'common-error' ) {
    $self->_set_cooldown( $repo, $karr );
    $self->_agents->record_failure( $agent->{name}, $result->{error} ) if $agent;
  } else {
    $self->_clear_cooldown( $repo );
    $self->_state_del( $repo, 'last_error' );
    if ( $agent && $self->_agents->record_success( $agent->{name} ) ) {
      $self->_say_verbose("agent '$agent->{name}' works again");
    }
  }

  # Update state
  my %state = (
    hash      => $self->_ref_hash( $repo ) // '',
    last_run  => localtime->datetime,
    last_exit => $result->{exit} // 0,
  );

  # The last run's own report, where it made one (#187): how it ended, how many
  # turns it took, how long it ran, what it cost. It is dropped again by a run
  # that reported nothing, for the same reason last_error is (#160): a key that
  # is still there describes the last run, and one describing a run three ticks
  # ago is a contradiction nobody reading .karr.state can resolve.
  if ( $result->{report} ) {
    $state{last_result} = $result->{report};
  }
  else {
    $self->_state_del( $repo, 'last_result' );
  }

  $self->_state_set( $repo, %state );
}

# ---------------------------------------------------------------------------
# Sync
# ---------------------------------------------------------------------------

sub _sync_pull {
  my ( $self, $repo ) = @_;
  $self->_say_verbose("sync --pull $repo");
  return if $self->dry_run;
  my $git = App::karr::Git->new( dir => "$repo" );
  return unless $git->is_repo;
  $git->pull;
}

# ---------------------------------------------------------------------------
# Ref hash (detect board changes)
# ---------------------------------------------------------------------------

sub _ref_hash {
  my ( $self, $repo ) = @_;
  my $git = App::karr::Git->new( dir => "$repo" );
  return undef unless $git->is_repo;
  my $oids = $git->ref_oids('refs/karr/') or return undef;
  # Deterministic fingerprint of refs/karr/* (ref name + target OID).
  my $out = join '', map { "$_ $oids->{$_}\n" } sort keys %$oids;
  return md5_hex( $out );
}

# ---------------------------------------------------------------------------
# Board-level disable flag (refs/karr/config: foundation.enabled)
# ---------------------------------------------------------------------------

# The board's own opt-out, stored in karr state rather than in the local .karr
# file so it syncs with the board and every foundation instance on every machine
# honours it. Returns { reason => $text_or_undef } when the board is disabled
# and undef when it is enabled (the default for a board that never set it).
sub _board_disabled {
  my ( $self, $repo ) = @_;
  my $git = App::karr::Git->new( dir => "$repo" );
  return undef unless $git->is_repo;
  my $store = App::karr::BoardStore->new( git => $git );
  return undef if $store->foundation_enabled;
  return { reason => $store->foundation_reason };
}

# Skip predicate used at the two checkpoints in _process_repo. True (and a
# verbose note) when the board is disabled.
sub _skip_disabled {
  my ( $self, $repo ) = @_;
  my $off = $self->_board_disabled( $repo ) or return 0;
  my $reason = $off->{reason};
  $self->_say_verbose(
    "skip $repo \x{2014} board disabled" . ( defined $reason ? ": $reason" : '' ) );
  return 1;
}

# ---------------------------------------------------------------------------
# Task state / actionability
# ---------------------------------------------------------------------------

# A task is actionable when an agent could still pick it: not terminal
# (done/archived) and not blocked. Mirrors `karr pick` eligibility.
sub _is_actionable {
  my ( $self, $st ) = @_;
  return 0 unless $st;
  return 0 if $st->{blocked};
  my $status = $st->{status} // '';
  return 0 if $status eq 'done' || $status eq 'archived';
  return 1;
}

# Snapshot every task as id => { status, claimed_by, updated, blocked }.
sub _task_states {
  my ( $self, $repo ) = @_;
  my $git = App::karr::Git->new( dir => "$repo" );
  return () unless $git->is_repo;
  my $store = App::karr::BoardStore->new( git => $git );
  my %states;
  for my $t ( $store->load_tasks ) {
    next unless $t;
    $states{ $t->id } = {
      status     => $t->status,
      claimed_by => ( $t->has_claimed_by ? $t->claimed_by : undef ),
      updated    => $t->updated,
      blocked    => ( $t->has_blocked ? 1 : 0 ),
    };
  }
  return %states;
}

sub _has_actionable_tasks {
  my ( $self, $repo ) = @_;
  my %states = $self->_task_states( $repo );
  for my $id ( keys %states ) {
    return 1 if $self->_is_actionable( $states{$id} );
  }
  return 0;
}

# ---------------------------------------------------------------------------
# Agent engagement (who this run's agent is, and what it touched)
# ---------------------------------------------------------------------------

# The activity log of the identity foundation runs its agent under. The Runner
# exports KARR_ROLE=agent to the command, so every nested `karr` write during
# the run lands in refs/karr/log/agent/<git-email> — the same identity this
# builds, since the agent runs in this repo with this repo's git config. Any
# other actor on the board (a human, another machine's agent) writes elsewhere.
sub _agent_log_entries {
  my ( $self, $repo ) = @_;
  my $git = App::karr::Git->new( dir => "$repo" );
  return () unless $git->is_repo;
  my $log = App::karr::ActivityLog->new( git => $git, role => 'agent' );
  return try { $log->entries } catch { () };
}

# An engagement record for one drain: the log entries already present when the
# drain started (so only what this drain adds counts), the task ids this run's
# agent has written to, and the claim names it wrote them under.
sub _new_engagement {
  my ( $self, $repo ) = @_;
  my @seen = $self->_agent_log_entries( $repo );
  return { seen => scalar @seen, ids => {}, claims => {} };
}

# Fold the entries the last command added into the record. Nothing else is
# evidence of engagement: a task that never shows up here was never touched by
# this run's agent, whatever its status or claim says.
sub _note_engagement {
  my ( $self, $repo, $eng ) = @_;
  my @entries = $self->_agent_log_entries( $repo );
  return $eng if @entries <= $eng->{seen};
  for my $entry ( @entries[ $eng->{seen} .. $#entries ] ) {
    my $id = $entry->{task_id};
    $eng->{ids}{ $id + 0 } = 1 if defined $id && $id =~ /\A[0-9]+\z/;
    my $who = $entry->{agent};
    $eng->{claims}{$who} = 1 if defined $who && length $who;
  }
  $eng->{seen} = scalar @entries;
  return $eng;
}

# True when the card is the agent's to penalize: unclaimed, or held under a
# name this run's agent itself wrote with. A claim belonging to anybody else —
# a human, another machine's agent, or this agent's own abandoned claim from an
# earlier run — is never ours to auto-block.
sub _agent_holds {
  my ( $self, $state, $claims ) = @_;
  my $owner = $state->{claimed_by};
  return 1 unless defined $owner && length $owner;
  return ( $claims // {} )->{$owner} ? 1 : 0;
}

# Tasks this run's agent engaged but did not move — still actionable, written
# to by the agent during this drain, held by nobody but the agent, and
# byte-identical before/after the last command. These are the only tasks that
# count toward an auto-block.
#
# Engagement is proven, never assumed: without an entry of the agent's own in
# $eng, foundation has no evidence it ever attempted the task, and an
# auto-block would be a destructive write to somebody else's card carrying a
# reason that is factually wrong (#158). So an engagement it cannot establish —
# an agent that does not write through karr, an unreadable log, a stale claim
# nobody touched this run — yields no stuck tasks and no auto-block at all.
# Failing to block a genuinely stuck card only leaves the drain to end on its
# iteration cap; blocking a stranger's card takes their work out of the
# actionable set behind their back.
sub _stuck_tasks {
  my ( $self, $before, $after, $eng ) = @_;
  my $ids    = ( $eng // {} )->{ids}    // {};
  my $claims = ( $eng // {} )->{claims} // {};
  my @stuck;
  for my $id ( sort { $a <=> $b } keys %$after ) {
    my $a = $after->{$id};
    next unless $self->_is_actionable( $a );
    next unless $ids->{$id};                      # the agent never touched it
    next unless $self->_agent_holds( $a, $claims ); # somebody else holds it
    next unless defined $a->{claimed_by} || ( $a->{status} // '' ) eq 'in-progress';
    my $b = $before->{$id} or next;   # newly created this run — give it grace
    next if ( $b->{status}  // '' ) ne ( $a->{status}  // '' );
    next if ( $b->{updated} // '' ) ne ( $a->{updated} // '' );
    push @stuck, $id;
  }
  return @stuck;
}

# ---------------------------------------------------------------------------
# Drain loop
# ---------------------------------------------------------------------------

# Run the agent repeatedly until the board has no actionable tasks left,
# auto-blocking tasks the agent keeps failing on. Returns
# { outcome => progress|stall|idle|common-error|error, exit => N, ticket => ID,
#   report => {...}, error => STR } (ticket is undef outside mode: ticket;
# error is set only on a common-error outcome).
# $agent is the named agent definition behind $cmd, or undef.
sub _drain_repo {
  my ( $self, $repo, $karr, $cmd, $agent ) = @_;
  my $max_runtime  = $karr->{max_runtime}    // 1800;
  my $max_attempts = $karr->{max_attempts}   // 2;
  my $max_iter     = $karr->{max_iterations} // 50;
  my $mode         = $self->_run_mode( $karr );
  my $drain        = $mode eq 'drain' ? 1 : 0;
  my $patterns     = $self->_error_patterns( $karr );

  # Use the resolved command, not $karr->{command}
  $cmd //= $karr->{command};

  # Ticket mode names the card before the agent starts, and the run is about
  # that card and nothing else. No card, no run: "run exactly one ticket" has
  # nothing to say when the board has no ticket to give, and an agent started
  # anyway would go looking for work of its own, which is the mode this one
  # exists to replace. --force and on_idle: always-run force the *check*, not a
  # run without a card.
  my $ticket;
  if ( $mode eq 'ticket' ) {
    $ticket = $self->_select_ticket( $repo );
    unless ( defined $ticket ) {
      $self->_append_log( $repo, "TICKET none assignable \x{2014} no agent run" );
      return { outcome => 'idle', exit => 0, ticket => undef };
    }
    $self->_append_log( $repo, "TICKET task#$ticket" );
  }

  my $loop_start = time;
  my $last_exit  = 0;
  my $outcome    = 'idle';
  my $first      = 1;
  my $iter       = 0;

  # The last run's own report, summarised (Runner::_result_summary), or undef
  # while no run has made one. It survives the loop so a drain hands back what
  # its final iteration reported.
  my $last_report;

  # The common error that ended the drain, where one did. It leaves the loop
  # because the caller needs it for two things now: .karr.state's last_error,
  # which the drain writes itself, and the named agent's availability record,
  # which is the caller's to write.
  my $error;

  # What this run's agent engages, accumulated across the whole drain: the
  # iteration that claims a task is the one that moves the board, so the stall
  # only becomes visible one or more iterations later.
  my $eng = $self->_new_engagement( $repo );

  while ( 1 ) {
    my %before = $self->_task_states( $repo );
    my @actionable = grep { $self->_is_actionable( $before{$_} ) } keys %before;

    # Once we have run at least once, stop when the board is drained, the
    # wall-clock budget is spent, or we hit the hard iteration cap. The
    # wall-clock check is skipped when max_runtime is 0: that value disables
    # the per-run timeout entirely (documented, Runner.pm), and the drain's
    # budget must not silently inherit the same "no limit" sentinel as a
    # hard zero — `>= 0` is always true after the first iteration and would
    # turn drain: true into a single run (#165). With max_runtime: 0 the
    # drain runs until the board is drained or the iteration cap.
    last if !$first && !@actionable;
    last if !$first && $max_runtime > 0 && ( time - $loop_start ) >= $max_runtime;
    last if $iter >= $max_iter;

    my $hash_before = $self->_ref_hash( $repo ) // '';
    my ( $exit, $output ) = $self->_run_command( $repo, $karr, $cmd, $ticket, $agent );
    $last_exit = $exit;
    $first     = 0;
    $iter++;

    my $hash_after = $self->_ref_hash( $repo ) // '';
    my $progressed = ( $hash_before ne $hash_after ) ? 1 : 0;

    # What the run said about itself, where it said anything: a claude-code
    # result object at the end of its output (Runner::_run_result explains how
    # foundation finds one and why it looks there and nowhere else). This is
    # the classification the text scan below has always been a stand-in for
    # (#187) — error flag, error kind, turns, duration, cost, stated by the
    # run rather than inferred from its prose.
    my ( $ended, $rerr );
    my $report = $self->_run_result( $output );
    if ( $report ) {
      ( $rerr, $ended ) = $self->_result_error( $report );
      $last_report = $self->_result_summary( $report, $ended );
      $self->_append_log( $repo, $self->_result_line( $report, $ended ) );
    }

    # Common error we can observe (bad exit, timeout, a report that says so, or
    # a known output pattern): don't penalize any task — leave the board
    # untouched and back off. What the run *did* is asked before what it
    # *printed* (#160): a run that exited 0 and moved the board did work,
    # whatever text went past on the way, and re-reading its own transcript is
    # the one way to lose that work — the drain aborted, the progress was
    # credited to nobody, and the cooldown climbed on every following run
    # because the board still said the same words. So the output is evidence
    # only where there is nothing else: a run that produced no board movement
    # at all. The genuine case the scan exists for looks exactly like that,
    # because an agent that hit a rate limit or a dead key could not move
    # anything.
    #
    # A report is not in that ordering at all, and this is the one place to be
    # careful not to invert it. The guard above protects the run from an
    # *inference*: a word search over megabytes the agent printed, which cannot
    # tell the agent's report from the board's own contents. A field in the
    # agent's own result object is not an inference, so it ranks with the exit
    # code rather than with the scan — and where there is a report, the scan
    # does not run at all. That is the whole point: an agent that prints a
    # backlog full of 503s and then reports success is a success.
    my $err;
    if ( $report ) {
      $err = $rerr;
      # A non-zero exit the report does not account for is still an error: the
      # report is claude's, the exit code may be the wrapper's, and a report of
      # success says nothing about a pipeline that failed after it (or about
      # the 128+SIGTERM the runner synthesizes for a run it had to kill). A
      # report that *does* carry an error flag has already accounted for it,
      # which is what lets a spent turn budget — claude exits 1 on
      # error_max_turns — stop parking the board for an hour.
      $err //= "exit=$exit" if $exit != 0 && !$report->{is_error};
    }
    elsif ( $exit != 0 ) {
      $err = "exit=$exit";     # or -1, the timeout — a hard signal, no scan
    }
    else {
      my $seen = $self->_match_error( $output, $patterns );
      if ( defined $seen && $progressed ) {
        # Worth saying once: an agent that reports a rate limit and still gets
        # a card moved is on its last legs, and the operator should hear it
        # from the log rather than from the next run's cooldown.
        $self->_append_log( $repo,
          "NOTE '$seen' in output, but the board moved \x{2014} not treated as an error" );
      }
      else {
        $err = $seen;
      }
    }

    if ( defined $err ) {
      # An exit-0 run that is thrown away is the surprising one; .karr.state
      # would otherwise carry last_exit: 0 next to last_error with nothing
      # anywhere saying why the run did not count.
      my $why = $exit == 0 ? " \x{2014} agent exited 0, run discarded" : '';
      $self->_append_log( $repo, "COMMON-ERROR $err$why" );
      $self->_state_set( $repo, last_error => $err );
      $outcome = 'common-error';
      $error   = $err;
      last;
    }

    my %after = $self->_task_states( $repo );
    $self->_note_engagement( $repo, $eng );

    my @stuck;
    if ( defined $ticket ) {
      # A ticket-mode run is judged by its own card, not by the board hash: an
      # agent that ignored its assignment and moved something else did move the
      # board, and calling that progress would tell the coordinator its ticket
      # was worked when it was not.
      if ( $self->_ticket_moved( \%before, \%after, $ticket ) ) {
        $outcome = 'progress';
      }
      else {
        $outcome = 'stall';
        # Which stall it was. "The agent reports it cannot proceed" and "the
        # agent did nothing" both end as a card that did not move, and until a
        # run reported for itself there was nothing to tell them apart with
        # (#187). Ticket mode is the caller that wants the difference most: it
        # is the one place foundation already knows what the run was supposed
        # to be about, so the only thing missing was what the agent made of it.
        $self->_append_log( $repo,
          "STALL task#$ticket \x{2014} " . $self->_stall_reason( $report, $ended ) );
        # foundation assigned this card, so it needs no activity-log evidence
        # that the agent engaged it -- the assignment is the evidence, and the
        # counter it bumps is foundation's own .karr.state. The auto-block a
        # few lines below is the destructive half, and that one keeps #158's
        # ownership guard: a card somebody else took during the run is never
        # blocked on our say-so.
        @stuck = ( $ticket )
          if $self->_agent_holds( $after{$ticket}, $eng->{claims} );
      }
    }
    else {
      $outcome = 'progress' if $progressed;
      @stuck = $self->_stuck_tasks( \%before, \%after, $eng );
    }

    # Reset the attempt counter for any task that is no longer stuck
    # (advanced, blocked, or gone), then bump/auto-block the stuck ones.
    my %is_stuck = map { $_ => 1 } @stuck;
    my $attempts = $self->_state_get( $repo, 'attempts' ) // {};
    $self->_reset_attempts( $repo, $_ ) for grep { !$is_stuck{$_} } keys %$attempts;

    for my $id ( @stuck ) {
      my $n = $self->_bump_attempts( $repo, $id );
      next if $n < $max_attempts;
      $self->_autoblock_task( $repo, $id,
        "auto-block: no progress after $n attempts (foundation)",
        $eng->{claims} );
      $self->_reset_attempts( $repo, $id );
    }

    # Agent did nothing useful and grabbed nothing — stop, nothing to attribute.
    # Not in ticket mode: there the run has already been judged against its own
    # card, and a stall foundation may not penalize (somebody else holds the
    # card now) is still a stall, not a run that found nothing to do.
    if ( !defined $ticket && !$progressed && !@stuck ) {
      $outcome = 'idle';
      last;
    }

    last unless $drain;   # single / ticket mode → one run and return
  }

  return {
    outcome => $outcome,
    exit    => $last_exit,
    ticket  => $ticket,
    report  => $last_report,
    error   => $error,
  };
}

# A ticket-mode stall, said in the terms a coordinator asks in. Without a
# report there is nothing to say and it says so, rather than guessing: an agent
# that produces no structured result is exactly the case foundation has no
# information about, and inventing a reason for it is how the text scan got
# into trouble in the first place (#160).
sub _stall_reason {
  my ( $self, $report, $ended ) = @_;
  return 'no report from the agent' unless defined $ended;
  return 'the agent ran out of turns'  if $ended eq 'max turns';
  return "the agent ended with $ended" if $ended ne 'success';
  return 'the agent reported success but the card did not move';
}

# Did the assigned card come out of the run different from how it went in?
# Gone, no longer actionable (done, blocked), or its blob rewritten — status or
# updated, the same two fields _stuck_tasks compares, so a claim, a status
# change and an appended note all count. Everything else is a run that did not
# touch its own ticket.
sub _ticket_moved {
  my ( $self, $before, $after, $id ) = @_;
  my $a = $after->{$id} or return 1;
  return 1 unless $self->_is_actionable( $a );
  my $b = $before->{$id} or return 1;
  return 1 if ( $b->{status}  // '' ) ne ( $a->{status}  // '' );
  return 1 if ( $b->{updated} // '' ) ne ( $a->{updated} // '' );
  return 0;
}

# ---------------------------------------------------------------------------
# Run mode / ticket selection
# ---------------------------------------------------------------------------

# What a run of this repo is: 'drain' (loop until the board stops moving, the
# historical default), 'single' (exactly one agent run, agent picks its own
# work) or 'ticket' (exactly one agent run, about a card foundation names).
#
# 'drain: true|false' said two thirds of this before there was a third answer,
# and it stays honoured rather than being deprecated into a warning: it is
# written in .karr files this foundation does not own. Two keys that both mean
# "one run" would be the trap, so they are one key with an alias, not two
# switches: 'mode' is asked first and 'drain' only answers when 'mode' is
# absent. Per-repo before global, as everywhere else here — a repo that says
# 'drain: false' means it against a config-wide 'mode: ticket', because the
# .karr file is the more specific statement.
sub _run_mode {
  my ( $self, $karr ) = @_;
  my $mode = $karr->{mode};
  unless ( defined $mode ) {
    return $karr->{drain} ? 'drain' : 'single' if exists $karr->{drain};
    $mode = $self->_config_data->{mode};
  }
  return 'drain' unless defined $mode;
  # A typo here is not a small mistake: 'ticekt' silently draining a board is
  # the opposite of what was asked for, on every tick, quietly. The caller
  # (_process_repo) turns this into a warning and skips the repo.
  user_error("Unknown mode '$mode' (expected: drain, single or ticket)")
    unless $mode eq 'drain' || $mode eq 'single' || $mode eq 'ticket';
  return $mode;
}

# The card a ticket-mode run is about, or undef when the board has none to
# give. Selection is a read: nothing is claimed and nothing is locked here —
# see App::karr::Foundation::Picker for why the claim stays the agent's.
sub _select_ticket {
  my ( $self, $repo ) = @_;
  my $git = App::karr::Git->new( dir => "$repo" );
  return undef unless $git->is_repo;
  my $store = App::karr::BoardStore->new( git => $git );
  return App::karr::Foundation::Picker->new( store => $store )->next_ticket;
}

# ---------------------------------------------------------------------------
# Auto-block (in-process via BoardStore, no karr CLI)
# ---------------------------------------------------------------------------

# $claims is the set of claim names this run's agent wrote under (see
# _note_engagement). The ownership test is repeated here, at the write itself,
# rather than trusted from _stuck_tasks: this is the one place that mutates
# somebody's card and pushes it, the board may have changed since the snapshot
# the caller decided on, and any future caller inherits the guarantee instead
# of having to remember it (#158).
sub _autoblock_task {
  my ( $self, $repo, $id, $reason, $claims ) = @_;
  return if $self->dry_run;
  my $git = App::karr::Git->new( dir => "$repo" );
  return unless $git->is_repo;
  my $store = App::karr::BoardStore->new( git => $git );
  my $task  = $store->find_task( $id ) or return;
  unless ( $self->_agent_holds(
      { claimed_by => ( $task->has_claimed_by ? $task->claimed_by : undef ) },
      $claims ) ) {
    $self->_append_log( $repo,
      "AUTOBLOCK-SKIP task#$id: claimed by " . $task->claimed_by );
    return 0;
  }
  $task->block( $reason );
  $store->save_task( $task );
  $git->push;   # best-effort propagate to remote
  $self->_append_log( $repo, "AUTOBLOCK task#$id: $reason" );
  return 1;
}

# ---------------------------------------------------------------------------
# Log file
# ---------------------------------------------------------------------------

sub _append_log {
  my ( $self, $repo, $msg ) = @_;
  my $ts  = localtime->strftime('%Y-%m-%dT%H:%M:%S');
  my $line = "[$ts] $$: $msg\n";
  print $line if $self->verbose;
  return if $self->dry_run;
  $repo->child('.karr.log')->append_utf8( $line );
}

sub _say_verbose {
  my ( $self, $msg ) = @_;
  print "$msg\n" if $self->verbose;
}

# ---------------------------------------------------------------------------
# .karr file
# ---------------------------------------------------------------------------

sub _load_karr {
  my ( $self, $repo ) = @_;
  my $karr_file = $repo->child('.karr');
  return {} unless $karr_file->exists;
  my $data = try {
    YAML::XS::LoadFile("$karr_file");
  } catch {
    warn "karr-foundation: cannot parse $karr_file: $_\n";
    {};
  };
  return ref $data eq 'HASH' ? $data : {};
}

# ---------------------------------------------------------------------------
# Agent command resolution
# ---------------------------------------------------------------------------

# What this repo runs, as ( $command, $invocation ). $command is the shell
# string, or undef when no agent is configured at all. $invocation is set only
# where the command came from a B<named> agent definition (see
# L<App::karr::Foundation::Agents>) and carries its name, kind and live-output
# rendering; it is undef for every other source, which is what keeps a board
# that knows nothing about agent definitions behaving exactly as before -- no
# availability is recorded against it, and nothing is appended to its command.
#
# Priority: CLI --command > config default_command > .karr command >
# .karr agent > config default_agent > 'claude: true' shorthand.
#
# A named agent sits below the literal command strings and above the claude
# shorthand: `command:` is the most specific thing a board can say (it is a
# whole invocation, written out), while `claude: true` is the oldest and least
# specific. A .karr `agent:` beats the config's `default_agent` for the same
# reason every other key here does -- the board is the more specific statement.
sub _resolve_agent {
  my ( $self, $repo, $karr ) = @_;
  my $cfg = $self->_config_data;

  for my $candidate ( $self->command, $cfg->{default_command}, $karr->{command} ) {
    return ( $candidate, undef ) if defined $candidate && length $candidate;
  }

  my $named = $karr->{agent} // $cfg->{default_agent};
  if ( defined $named && length $named ) {
    # An unknown name raises: a typo here is not a small mistake. Silently
    # falling back to no agent would park the board for good and say nothing,
    # which is what `mode:` refuses to do for the same reason. _process_repo
    # runs inside run()'s per-repo try, so this warns and skips one board.
    my $inv = $self->_agents->invocation( $named );
    return ( $inv->{command}, $inv );
  }

  my $claude = exists $karr->{claude} ? $karr->{claude} : $cfg->{claude};
  return ( $self->_claude_command($karr), undef ) if $claude;

  return ( undef, undef );
}

# The resolved agent command string, or undef when no agent is configured.
sub _agent_command {
  my ( $self, $repo, $karr ) = @_;
  my ( $cmd ) = $self->_resolve_agent( $repo, $karr );
  return $cmd;
}

# Synthesize the canonical claude invocation behind 'claude: true'. The $PROMPT
# variable is substituted from $ENV{PROMPT} at run time (see _run_command), so
# users never retype the long flag set. claude_bin / claude_max_turns /
# claude_permission_mode override the defaults (per-repo, then global).
sub _claude_command {
  my ( $self, $karr ) = @_;
  my $cfg = $self->_config_data;
  my $bin   = $karr->{claude_bin}             // $cfg->{claude_bin}             // 'claude';
  my $turns = $karr->{claude_max_turns}       // $cfg->{claude_max_turns}       // 30;
  my $perm  = $karr->{claude_permission_mode} // $cfg->{claude_permission_mode} // 'bypassPermissions';
  return qq{$bin -p "\$PROMPT" --permission-mode $perm --max-turns $turns};
}

# The agent instruction exposed as $PROMPT. .karr 'prompt' > config
# 'default_prompt' > the built-in default.
#
# With a $ticket the built-in default changes (the ordinary one opens by
# telling the agent to pick its own work) and the assignment sentence is
# appended to whatever prompt was resolved. Appending rather than replacing
# keeps a configured prompt doing its job — it is usually about which skill to
# use and how to report — while the last sentence, which is the one that wins
# with a language model, is the one naming the card. Without this the mode
# would be `drain: false` with extra steps: the agent would never learn which
# ticket it was given.
sub _prompt_for {
  my ( $self, $karr, $ticket ) = @_;
  my $configured = $karr->{prompt} // $self->_config_data->{default_prompt};
  return $configured // $DEFAULT_PROMPT unless defined $ticket;
  return ( $configured // $DEFAULT_TICKET_PROMPT ) . "\n\n"
       . sprintf( $TICKET_ASSIGNMENT, $ticket );
}

1;
