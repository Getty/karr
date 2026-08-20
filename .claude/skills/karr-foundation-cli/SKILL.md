---
name: karr-foundation-cli
description: Use when running karr-foundation — periodic agent execution across several karr boards, drain loops, ticket mode, named agents, the coordination agent and its assignment, the hub chain and question mailbox, auto-block logic.
---

# karr-foundation — Periodic Agent Executor for karr Boards

Single-shot daemon that monitors multiple karr boards and runs an agent command
when work is available. Designed for cron/systemd-timer invocation.

## Quick start

```bash
# Config at ~/.config/karr-foundation/config.yml
dirs:
  - /path/to/repo1
  - /path/to/repo2
scan:
  - /path/to/parent-dir   # finds dirs with .karr file

# Per-repo .karr file (in each repo root)
command: claude -p "Use karr-coordinator agent, pick next task"
on_idle: skip
drain: true
max_runtime: 1800
max_attempts: 2

# Run via cron every 5 minutes
*/5 * * * * karr-foundation
```

## Config file

Default: `~/.config/karr-foundation/config.yml`

```yaml
dirs:
  - /path/to/repo1
  - /path/to/repo2

scan:
  - /path/to/parent-dir   # finds direct children with .karr file

concurrent: 4             # boards that may have an agent at once (default: 1)
hub: /path/to/hub-repo    # the repo carrying refs/karr-foundation/* (the chain)
routing: >-               # prose for the coordination agent; karr never parses it
  minimax is cheap and does the routine work. Never hand it a release.
```

## Per-repo .karr file

Place in repo root. All keys optional. Agent execution is opt-in: a board runs
an agent only if one of seven sources names a command, and the first one that
does wins:

```
--command  >  config default_command  >  .karr command  >  .karr agent
           >  the assignment  >  config default_agent  >  claude: true
```

A literal command string is the most specific thing that can be said, a named
agent (see "Named agents") sits below it, and `claude: true` is the oldest and
least specific. The assignment (see "The coordination agent") is the routing
table written for this machine: it is asked only for a board that names no
agent of its own, and it beats `default_agent` because it is per repository
where that is per fleet. A board naming an agent the config does not define is
an error that skips **that board**, not one that silently stops running. With
no agent on any board, `karr-foundation` prints a read-only overview instead of
running anything (see "Overview").

```yaml
claude: true              # synthesize the canonical claude command (opt-in)
claude_bin: claude        # binary for claude: true (default: claude)
claude_max_turns: 30      # --max-turns for claude: true (default: 30)
claude_permission_mode: bypassPermissions   # (default: bypassPermissions)
prompt: >-                # agent instruction, exposed to the command as $PROMPT
  Use the karr-coordinator skill: pick the next actionable task and move it.
# command: claude -p "$PROMPT"   # explicit command; wins over claude: true
# agent: minimax          # a named agent from the config's 'agents:' section
on_idle: skip             # 'skip' (default) | 'always-run'
mode: drain               # drain (default) | single | ticket
drain: true               # older spelling of mode: true=drain, false=single
max_runtime: 1800         # seconds: per-run TERM, then KILL 2s later (0 = off)
max_attempts: 2           # stalls on one task before auto-block (default: 2)
max_iterations: 50        # hard cap on drain iterations / drain budget (default: 50)
cooldown_base: 1          # cooldown minutes at level 0 (default: 1)
cooldown_max: 64          # cooldown ceiling in minutes (default: 64)
error_patterns:           # extra case-insensitive substrings → common-error
  - my custom api error
on_drained: ./release-gate.sh   # run when the board has no work left
on_drained_max_runtime: 1800    # seconds for that command (0 = no limit)
on_drained_max_rounds: 3        # see "The domain hook" (0 = no cap)
```

`claude`, `claude_bin`, the other `claude_*` knobs, `mode` and the three
`on_drained*` keys may also be set in `config.yml` under the same name;
`command`, `prompt` and `agent` have config-wide spellings of their own
(`default_command`, `default_prompt`, `default_agent`). The per-repo `.karr`
value wins in every case — including `on_drained: ""`, which is how one board
opts out of a fleet-wide hook.

## Named agents

A board has one command; a fleet has several agent commands with different
strengths and different failure modes. `config.yml` names them, a `.karr` picks
one with `agent:`:

```yaml
agents:
  minimax:
    command: claude_with_minimax
    kind: claude-code       # the invocation contract; default: shell
    probe_every: 15m        # retry interval once it stops working
    permission_mode: bypassPermissions    # kind: claude-code only
    max_turns: 30                         #   "     "        "
    allowed_tools: [ Bash, Edit ]         #   "     "        "
    concurrent: 2           # runs of THIS agent at once — see "Concurrency"
    description: >-
      Prose. What this agent is good at, where it is weak, what it costs.
  planner:
    command: claude
    kind: claude-code
    role: coordinator       # the fleet's judgement layer — see below

default_agent: minimax    # for boards whose .karr names none
probe_every: 10m          # fleet-wide default for agents that name none
```

`kind` says what karr may append to `command`. `shell` (the default) is a
complete template karr appends **nothing** to — it cannot know what the thing
at the other end understands. `claude-code` gets `-p "$PROMPT"`,
`--output-format stream-json --verbose --include-partial-messages`, and
`--permission-mode` / `--max-turns` / `--allowed-tools` from the definition;
stream-json rather than plain `json` because karr needs the run's own result
object *and* the live output, and plain `json` prints nothing until the run
ends. The ticket of a `mode: ticket` run is never appended — it travels as
`$PROMPT`'s closing sentence and as `$KARR_TASK`.

`description` is never read by karr. It is carried for the agent that routes
work across the fleet: the thing choosing is a language model and reads prose,
so there are no classes and no enums. `--status --verbose` prints it.

`role` marks the one agent that is the fleet's judgement layer (see "The
coordination agent"). `coordinator` is the only value; anything else is a config
error, and two marked definitions are refused rather than guessed between —
"which of these is the judgement layer" has no safe default. `--status` prints
`(coordinator)` beside it.

**Availability.** karr keeps the least it can per agent: `ok`, or `failing`
since a moment with the next attempt due at another. No cost, no tokens, no
quotas — a rate limit and a spent budget look identical from the outside. A
drain ending in `common-error` marks its agent failing; any other outcome says
it works. While an agent is failing, **every** board on it is skipped, and
`--force` does not override that either — the wait is bounded by `probe_every`
and ends by itself. When the next attempt comes round the agent is simply run
again on the work that was waiting: the probe **is** the run, and every
recovery is recorded so a rhythm can be read out later.

Agent definitions are **local and only local** — never board state, never
synced: a command that exists on one machine does not exist on the next, and an
account limit belongs to a person, not to a project. The availability record
lives beside the config that defines them (`agents.state` next to
`config.yml`, so `--config` relocates it), flock'd because every board on the
machine shares it.

## Run mode

`mode` says what one pass over a repo is:

- **`drain`** (default) — run the agent again and again until the board stops
  moving. See "Drain loop semantics".
- **`single`** — exactly one agent run; the agent still chooses its own work.
- **`ticket`** — exactly one agent run, about **one card foundation names**.

`drain: true|false` is the older spelling of the first two (`true` = `drain`,
`false` = `single`) and still works. They are one key with an alias, not two
switches: `mode` is asked first, `drain` answers only when `mode` is absent, and
a per-repo `drain` still beats a config-wide `mode`. An unrecognised `mode` is an
error that skips that repo, never a silent fall back to draining it.

### Ticket mode

Before the agent starts, foundation picks the card the run is about — `karr
pick`'s eligibility (not terminal, not blocked, not held by a live claim; an
expired claim no longer holds one) and `karr pick`'s ranking (class, then
priority, then id). The agent is told twice: the id is spliced into `$PROMPT` as
a closing sentence, and exported as `$KARR_TASK` for a command template that
wants the bare number. Nothing is appended to the command itself.

Foundation names the card; it does **not** claim it. The claim is the agent's
work session (`karr agentname`, then the same name for `move` and `handoff`),
and `.karr.lock` plus one-agent-per-repository already keep anybody else off the
card for the length of the run. An agent that dies leaves at most its own claim
— cleared by `claim_timeout`, or by `karr unlock` for a pick lock — and one
attempt.

The run is judged by that card, not by the board hash: **progress** when it
moved, **stall** when it did not, whatever else on the board moved meanwhile. A
stall bumps that card's attempt counter and auto-blocks it at `max_attempts`,
under the same ownership guard as a drain. With no assignable card, **no agent
is started at all** (`TICKET none assignable` in `.karr.log`, outcome `idle`);
`--force` and `on_idle: always-run` force the check, not a run without a card.

## Concurrency

Default: **one board at a time**, which is what this has always been.
Concurrency is opt-in like agent execution itself. Three levels bound what runs
and the **tightest one wins**:

1. `concurrent:` in `config.yml` — the machine ceiling. Protects this box's CPU
   and memory; it is not a quota. Default `1`.
2. `concurrent:` on a named agent definition (the `agents:` section) — the
   operator's estimate of where that agent's session limit sits. It is allowed
   to be wrong: being wrong makes the agent start failing, which parks every
   board on it for one probe interval and lets the fallback take over.
3. `limits:` in the chain header, for the fleet's current plan:

   ```yaml
   limits:
     concurrent: 4
     per_agent:
       minimax: 2
   ```

   The `per_agent` names are agent definition names. One this machine does not
   define is dropped with a `--verbose` note, not refused: agent definitions
   are local and only local.

**One agent per repository, always.** The unit of concurrency is one board, run
by one forked child that owns that board's `.karr.lock` for the length of its
drain. Two agents in one working tree would collide over the index and the
checkout, so concurrency is across repositories and never inside one; anything
else would need a git worktree per agent and is out of scope.

A signal to `karr-foundation` takes every running agent with it: the parent
TERMs its children and each child kills its own agent's process group and
releases its own lock, exactly as a serial run does.

`--dry-run` stays serial whatever the ceiling says.

`hub:` names the one repository of a fleet that carries
`refs/karr-foundation/*`. That namespace is pulled once at the start of a run,
before the chain header is read, so a tick applies the fleet's current limits
and not whatever this machine last happened to fetch. Nothing is pushed back —
this run reads the header and writes no step state.

## The hub: chain and questions

Every command here works out of the hub, and each is an error without one
rather than a quiet local no-op — chain and mailbox are fleet state.

**`karr-foundation plan`** writes the chain. It takes the whole chain as one
YAML document on stdin (JSON reads through the same parser), or from the file
`--input` names, and **replaces** what the hub holds:

```bash
karr-foundation plan <<'CHAIN'
steps:
  - id: 1
    kind: ticket
    repo: /srv/karr
    ticket: 41
    precheck: ticket_status == todo
  - id: 2
    kind: shell
    repo: /srv/karr
    needs: [ 1 ]
    command: ./release-gate.sh
limits:
  concurrent: 2
note: what this plan is for
CHAIN

karr-foundation plan --dry-run < chain.yml   # check it, write nothing
```

A document rather than options, because a DAG is nested and the writer that
matters most — the coordination agent — already produces structure; a bare list
of steps is a document too. It replaces rather than appends because only steps
whose chain id matches the header are ever ready, so an append would be a new
chain over old steps and new ones with a merge policy of its own. The step keys
are the ones under "Step kinds" below (`id`, `kind`, `repo`, `ticket`, `needs`,
`timeout`, `precheck`, `command`, `note`, plus `on_*` policies) and beside
`steps:` the document takes `limits:`, `note:` and `planner:` — nothing else,
so a misspelled key is refused instead of silently doing nothing. The whole
document is validated before the first ref is written: a chain karr will not
take leaves the one in the hub untouched, and a chain that still has a step
`running` is refused unless `--force`.

**`karr-foundation chain`** executes what the plan in the hub says is ready. It
pulls the namespace first and refuses the tick when that fails (everywhere else
a failed fetch is a warning; here the fallback would be running a step another
machine is already running), measures each step's precheck against facts it
reads off the boards, runs it, and pushes the step state and the run log back.

```bash
karr-foundation chain              # execute what is ready
karr-foundation chain --dry-run    # list the ready set and its verdicts
```

Step kinds: `ticket` goes through the target repo's **ticket mode**, `shell`
runs a command in the target repo under that repo's own lock, `question`
resolves a mailbox question under its policy, `plan` is recognised and left
pending — and where the fleet marks a coordination agent, a plan step is one of
the four deviations that call it once at the end of the tick. The chain is a layer **above** the run modes and not a fourth `mode:`
— a step inherits the board lock, the claim discipline, the ownership guard and
the run's own report from the mode it calls. A `failed` step stops its own
branch by construction (a step is released only when everything it `needs` is
`done`); a common error and a skipped board (disabled, locked, in cooldown, on
a failing agent) requeue it as `pending` instead, and a step naming a
repository this machine does not have is left untouched and unclaimed. With a hub but no chain written, this says so and returns 0.

**The question mailbox.** A question is a file with an answer field, not a
dialogue — which is what removes the special case for "a human happens to be
present". The chain writes one and carries on with everything that does not
depend on it; whoever answers needs to know nothing about the chain.

```bash
karr-foundation ask "Which registry do we publish to?" \
    --context "the release gate is waiting" \
    --options cpan,darkpan --default cpan --policy use_default \
    --wait 3600 --step 4

karr-foundation answer 7 darkpan --note "this release is a private one"
```

`--policy` is what happens when nobody answers: `block` (the default: wait),
`use_default` (`--default` becomes the answer once `--wait` seconds have
passed) or `escalate_to_ai` (the question is handed to the coordination agent
at the end of the tick where the fleet marks one, and recorded and left waiting
where it does not — the step is never answered on that agent's behalf). `--step` names the chain step waiting on the answer. Both commands
sync the fleet namespace around what they write. `answer` refuses an id that
already has an answer and an answer outside `--options`; `--force` overrides
both. `--status` lists the open mailbox with the id each one is answered by;
answered questions age out, open ones never do.

## The coordination agent

The third layer of the design, and the only one that is an AI: coordination is
shared state in refs, execution is local, and **judgement** — planning, routing,
reacting to what nobody planned for — is an agent. It is an agent like every
other one: an entry in `agents:`, invoked through its own `command` under its
own `kind` contract, classified from its own result object, and marked
`failing` by the same availability record. What sets it apart is **when** it
runs, which is never in the hot path. `karr-foundation` works through written
plans by itself and calls this one only where a plan is missing or has broken;
between two of those, no AI runs at all.

Which agent it is, is the `role: coordinator` marker on its definition (see
"Named agents") — not a second config key naming an agent that is already
named. A fleet that marks none behaves exactly as it did before: the deviations
are printed, and the operator is the planner.

**Four deviations, one call per tick.** Every one of them was already a place
that recorded "the planner is wanted" and nothing else:

- a `kind: plan` step
- a question past its deadline whose policy is `escalate_to_ai`
- a step whose precheck no longer holds (`stale`)
- a repository the assignment cannot route

A tick collects them and makes **one** call at the end of itself, carrying all
of them: five deviations in one tick are one thing learned — the plan is out of
date — and five calls would pay five times to hear it. The call is last because
a planner called half way through would plan against a board the tick was still
moving, and nothing is re-read afterwards: what it wrote is what the **next**
tick runs.

The run happens in the hub, under the hub's own `.karr.lock` (one agent per
repository holds there too), with `KARR_ROLE=coordinator`, and with its
instruction in `$PROMPT`: the deviations, where the fleet's files are, every
agent with its availability and its prose, and the operator's own `routing:`
prose from `config.yml`. Without a hub it is not called and says so once — a
chain and a question live in `refs/karr-foundation/*`, so there would be nowhere
to put the answer. While the coordination agent itself is failing it is not
called either, and the place that wanted it simply waits.

```console
$ karr-foundation
calling the coordination agent 'planner' for 2 deviation(s): step replan: kind: plan is not executed here; /srv/docs-site: no assignment names this repository
the coordination agent 'planner' finished (success); the next tick runs what it wrote
```

**The assignment** is what it writes so that routing needs no AI afterwards —
`assignment.yml`, beside `config.yml` and `agents.state`, so `--config`
relocates it with them:

```yaml
repos:
  /srv/docs-site:
    - minimax
    - claude
    - WAIT
```

Repository path to an ordered list of agents. `karr-foundation` looks the
repository up and takes the **first entry that currently works**; `WAIT` means
"rather wait than use anything further down" and ends the search, and so does a
chain whose agents are all failing. Such a board runs nothing this tick and says
so (`agent-waiting` in the overview) instead of reading as a board nobody
configured an agent for; `--force` does not override that, exactly as it does
not override a cooldown or an agent's availability. An agent name this machine
does not define is skipped with a `--verbose` note and the next one is tried —
definitions are local, so a table written where more of them exist is a normal
thing to meet.

Like the definitions it names, the assignment is **local and never in refs**: a
command that exists on one machine does not exist on the next, so a table naming
agents cannot be shared any more than they can.

What it is **not**: nothing domain-specific reaches karr through it (that is
`on_drained` and the operator's prose), it is no learning algorithm (the
recovery records are read by the agent, not by karr), it lifts no block, and it
does not touch one-agent-per-repository.

## Board-level disable

A board can opt out of automated agent runs in **its own karr state**, not in the
local `.karr` file:

```bash
cd /path/to/repo
karr disable --reason "abandoned driver, backlog parked"
karr enable                                  # allow agent runs again
```

The flag is `foundation.enabled` in `refs/karr/config`, so it syncs with the
board — every foundation instance on every machine honours it. That is the
difference to `.karr`, which is local machine state and cannot express "this
board is parked" for the whole fleet.

**Precedence — absolute.** A disabled board is skipped **whole**: the flag is
checked before the agent command is resolved and before the drain decision, so
there is no drain, no auto-block and no agent run. It wins over every source in
the resolution order above — `--command`, the config's `default_command`, the
`.karr` `command`, a named `agent`, the assignment, `default_agent`, and
`claude: true` — and
`--force` does **not** override it. A `kind: shell` chain step aimed at a
disabled repo is left `pending` for the same reason. Disabled means disabled.

This closes the gap where a global `default_command` in `config.yml` turned
every discovered board into an agent board with no way for a repo to opt out.
Use it for a repository whose backlog is parked rather than abandoned, so an
automation host that drains every discovered board leaves this one alone.

The same state is readable and writable through `karr config`:

```bash
karr config get foundation.enabled           # -> 0 or 1
karr config set foundation.enabled false     # true/false, yes/no, on/off, 1/0
karr config set foundation.reason "why"
```

`karr disable` without `--reason` clears any previously stored reason. When
every discovered board is disabled (or has no agent), `karr-foundation` falls
back to the overview instead of draining.

## Overview

`karr-foundation --status` (and the default when no board has an agent) prints a
read-only dashboard of every board: status counts, in-progress/blocked tasks,
and disabled/lock/cooldown state. No agent is run — usable by a human to
coordinate work.

```
dbio-informix
  7 tasks  [disabled]
  backlog:5  review:2
  disabled:    abandoned driver, backlog parked
```

`disabled` leads the flag list and the `disabled:` line carries the reason
(`no reason given` when none was stored). The `agent` flag is suppressed for a
disabled board, because that agent will never run there; otherwise it names
which agent (`agent:minimax`, plus ` failing` when that one is unavailable). A
board the assignment routes to nothing runnable right now gets `agent-waiting`
and a `waiting:` line with the reason — it is an agent board whose agents are
down, not a board nobody configured, and the two are fixed by different things.
The boards are followed by an `Agents` block where the local config defines any
(`ok`, or `failing since … next attempt at …`, with `(coordinator)` beside the
one marked as such; `--verbose` adds each one's kind and description) and by the
hub's open questions where there are any.

## Options

```bash
karr-foundation --config PATH       # custom config file
karr-foundation --force             # run even if no board change / open tasks
karr-foundation --dry-run --verbose # preview without executing
karr-foundation --status            # read-only overview of every board, no runs
```

Agent output streams to the terminal when run interactively (TTY) or with
`--verbose`, and is always appended to `.karr.log`.

## Exit codes

The same contract as `karr` (ADR 0002), because `ask`, `answer` and `chain` are
typed by people and scripted by agents, not only run by cron:

- **0** — the tick finished: boards drained, an overview printed, a question
  asked or answered, the chain worked through. A chain step that **failed**
  does not change this — that is a statement about the plan, not about this
  binary.
- **1** — runtime failure: no repository discovered, a config that does not
  parse, a hub command with no hub, an answer to a question that already had
  one, or `chain` unable to fetch `refs/karr-foundation/*`.
- **2** — usage error: an unknown command, an unknown option, an invalid option
  value, a missing or surplus positional argument.

A run killed by `SIGTERM`, `SIGINT` or `SIGHUP` exits `128 + signal` after
taking its agents down with it.

## Drain loop semantics

Each iteration runs `command` once, then classifies result:

| Outcome | Meaning | Action |
|---------|---------|--------|
| **progress** | board changed | keep draining |
| **stall** | a task *this run's agent engaged* didn't move | bump attempt counter; auto-block after `max_attempts` |
| **common-error** | bad exit, timeout, or an error pattern in a run that moved *nothing* | exponential backoff, no task penalty |
| **idle** | agent did nothing, grabbed nothing | stop |

**What a run did is asked before what it printed.** A run that exited 0 and
moved the board is progress whatever scrolled past it, and is never
reclassified by its own transcript; the output is scanned only for a run that
moved nothing at all — which is what a rate-limited or unauthenticated agent
looks like. A pattern seen in a run that *did* move the board is noted in
`.karr.log` and otherwise ignored. The default patterns are narrow to match: a
symptom word counts next to a failure word on the same line (`network error`,
`invalid credentials`, `quota exceeded`), and an HTTP status only where
something adjacent marks it as one (`API error: 429`, `429 Too Many Requests`)
— not in a diffstat, a byte count or a line number. Before that, an agent
printing its own board tripped the scan on a backlog title and throttled a
healthy board to one run per hour (#160).

### Auto-block

When a task is stuck after `max_attempts`, foundation marks it blocked with:
```
blocked: auto-block: no progress after N attempts (foundation)
```
Agent can override with `karr edit --block "reason"`.

**Engaged** means foundation can prove the agent worked that card during *this*
drain: it runs the command with `KARR_ROLE=agent`, so the agent's `karr` writes
land in the board's activity log under the `agent` identity, and only tasks
named there — unclaimed, or held under a claim name the agent itself wrote
with — can be penalized. A card somebody else holds is never auto-blocked,
nor is one the agent merely left claimed in an earlier run (that is what
`claim_timeout` and `karr unlock` are for). Without that evidence — an agent
command that never calls `karr` — foundation auto-blocks **nothing** rather
than guess (#158).

### Exponential cooldown

On common-error: repo waits `cooldown_base × 2^level` minutes (capped at `cooldown_max`).
Level resets on next clean (non-error) run, which also drops `last_error` from
`.karr.state` — it describes the last run, not a past one.

## The domain hook (`on_drained`)

When a board has **drained** — no actionable task left on it, everything done,
archived or blocked — `on_drained` runs a configured command in it. karr does
not know what that command does and must not: the exit code goes to `.karr.log`
and `.karr.state` and is interpreted by nobody. A hook that fails does not park
the board, does not mark the board's agent failing and is never the run's
`last_error`; it is not an agent run and is not classified as one, so no report
is read out of it, no error pattern is matched against it, no ticket is
assigned to it.

It is told where it is and nothing else: `KARR_REPO`, and `KARR_ROLE=hook` so
its own `karr` writes land in their own activity log instead of counting as the
agent's engagement with a card. `PROMPT` and `KARR_TASK` are empty. It runs in
the board's directory, under the board's own `.karr.lock`, with the same
process-group kill and the same tee to `.karr.log` an agent gets — but on its
own budget, `on_drained_max_runtime` (default 1800), because how long an agent
may take says nothing about how long a release gate may.

A drain that ended in `common-error` does not count as drained: a rate-limited
agent leaves a board that looks exactly like one it worked through, and
foundation does not believe that run. Two guards bound the hook, and `--force`
overrides both:

- **The same board is not asked twice.** The board fingerprint the hook last
  ran at is kept in `.karr.state`; a board that has not moved since gets no
  second run — otherwise a repository nobody touches starts a gate on every
  tick for ever, because a drained board stays drained.
- **A chain that never settles is capped.** Consecutive rounds in which the
  hook itself put work back on the board are counted; a run that leaves the
  board alone — the gate that finally passed — clears the count, and at
  `on_drained_max_rounds` (default 3, `0` disables) the hook is suppressed with
  a line in `.karr.log`.

A hook that files tickets is the point, not a failure mode: the board is no
longer drained, the next tick works them, the board drains again and the hook
is asked again.

## State files (gitignored)

```
.karr.state   # board hash, per-task attempts, cooldown, last error, last
              # report, and the hook's fingerprint / rounds / last exit
.karr.lock    # flock'd lock: one agent per repo, however many ticks knock
.karr.log     # run log
```

Agent availability is not among them — it is not per board and does not live in
the repository at all (see "Named agents"), and neither is the assignment (see
"The coordination agent"). Both sit beside `config.yml`.

## Environment

During agent execution foundation sets:

- `KARR_REPO` — the repo path
- `KARR_ROLE` — the identity nested `karr` calls write under: `agent` for an
  agent run (`refs/karr/log/agent/<email>`), `hook` for `on_drained`, `chain`
  for a `kind: shell` chain step, `coordinator` for the coordination agent; a
  human defaults to `user`
- `PROMPT` — the resolved agent instruction (`prompt` / `default_prompt` /
  built-in default), referenced as `$PROMPT` in the command template; in ticket
  mode it ends with the sentence naming the assigned task, for a hook it is
  empty, and for the coordination agent it is that agent's own instruction
  rather than the board's
- `KARR_TASK` — the id of the task a `mode: ticket` run was given, empty in
  every other mode

## Cron example

```bash
# Every 5 minutes, all repos
*/5 * * * * karr-foundation

# With verbose logging to syslog
*/5 * * * * karr-foundation --verbose 2>&1 | logger -t karr-foundation
```

## Enabling agent runs for a repo fleet

Each repo needs a `.karr` file with a command that invokes an agent on the
next available task. Example:

```yaml
command: claude -p "Use karr CLI to pick next task, implement it fully, hand off or close"
on_idle: skip
drain: true
max_runtime: 900
max_attempts: 2
cooldown_base: 2
cooldown_max: 32
```

To initialize karr in a repo:
```bash
cd /path/to/repo
karr init --name my-project
karr create "Example task" --priority high
```

Then add the `.karr` file and configure foundation to scan the parent dir.

To take a single repo out of a fleet that runs on a global `default_command`,
run `karr disable --reason "why"` in that repo — see "Board-level disable".
