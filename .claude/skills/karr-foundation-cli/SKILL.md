---
name: karr-foundation-cli
description: Use when running karr-foundation — periodic agent execution across several karr boards, drain loops, ticket mode, auto-block logic.
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
```

## Per-repo .karr file

Place in repo root. All keys optional. Agent execution is opt-in: a board runs
an agent only if it has `command` **or** `claude: true`. With no agent on any
board, `karr-foundation` prints a read-only overview instead of running
anything (see "Overview").

```yaml
claude: true              # synthesize the canonical claude command (opt-in)
claude_bin: claude        # binary for claude: true (default: claude)
claude_max_turns: 30      # --max-turns for claude: true (default: 30)
claude_permission_mode: bypassPermissions   # (default: bypassPermissions)
prompt: >-                # agent instruction, exposed to the command as $PROMPT
  Use the karr-coordinator skill: pick the next actionable task and move it.
# command: claude -p "$PROMPT"   # explicit command; wins over claude: true
on_idle: skip             # 'skip' (default) | 'always-run'
mode: drain               # drain (default) | single | ticket
drain: true               # older spelling of mode: true=drain, false=single
max_runtime: 1800         # seconds: per-command SIGKILL (0 = no timeout)
max_attempts: 2           # stalls on one task before auto-block (default: 2)
max_iterations: 50        # hard cap on drain iterations / drain budget (default: 50)
cooldown_base: 1          # cooldown minutes at level 0 (default: 1)
cooldown_max: 64          # cooldown ceiling in minutes (default: 64)
error_patterns:           # extra case-insensitive substrings → common-error
  - my custom api error
```

`claude`, `claude_bin`, the `claude_*` knobs, `command`, `mode` and `prompt` may also be
set globally in `config.yml` (`default_command` / `default_prompt`); the per-repo
`.karr` value wins.

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
there is no drain, no auto-block and no agent run. It wins over `--command`, the
config's `default_command`, the `.karr` `command` and `claude: true`, and
`--force` does **not** override it. Disabled means disabled.

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
disabled board, because that agent will never run there.

## Options

```bash
karr-foundation --config PATH       # custom config file
karr-foundation --force             # run even if no board change / open tasks
karr-foundation --dry-run --verbose # preview without executing
karr-foundation --status            # read-only overview of every board, no runs
```

Agent output streams to the terminal when run interactively (TTY) or with
`--verbose`, and is always appended to `.karr.log`.

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

## State files (gitignored)

```
.karr.state    # board hash, per-task attempts, cooldown, last error
.karr.lock    # flock'd lock: one agent per repo, however many ticks knock
.karr.log     # run log
```

## Environment

During agent execution foundation sets:

- `KARR_REPO` — the repo path
- `KARR_ROLE=agent` — so nested `karr` calls log under the `agent` identity
  (`refs/karr/log/agent/<email>`); a human defaults to `user`
- `PROMPT` — the resolved agent instruction (`prompt` / `default_prompt` /
  built-in default), referenced as `$PROMPT` in the command template; in ticket
  mode it ends with the sentence naming the assigned task
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
