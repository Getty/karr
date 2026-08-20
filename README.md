[![karr — a llama signalman at a lever frame, routing kanban cards across tracks](https://raw.githubusercontent.com/Getty/karr/main/assets/github.png)](https://github.com/Getty/karr)

# App::karr

Git-native kanban for shared helper agents, human operators, and downstream
repos that want a board without checking a board directory into the work tree —
and `karr-foundation`, the coordinator that keeps agents working across many of
those boards unattended.

`karr` keeps canonical state in `refs/karr/*`, not in commits, branches, or a
checked-in board directory. Tasks, config, logs, snapshots, and helper refs move
through normal Git transport, which makes the tool fit naturally into AI-heavy
and multi-machine workflows.

## Why it exists

Most task tools assume a central web service or a checked-in file tree.
`karr` takes a different route:

- board state lives in Git refs
- mutating commands pull the refs, write the change back into them, and push
- tasks stay separate from branches and commits
- downstream projects can vendor the CLI through Docker and keep the exact same UX
- `karr-foundation` runs the boards: it scans repositories, decides where there
  is work, and runs an agent there — or, with no agent configured anywhere,
  simply shows you every board at once

That gives you a shared board with far fewer file-level collisions and without
having to bolt on another ticket system just to coordinate agents.

## Quick start

Inside an existing Git repository:

```bash
karr init --name "My Project"
karr create "Fix login bug" --priority high
karr list
karr board
```

Claim and progress work:

```bash
NAME=$(karr agentname)
karr pick --claim "$NAME" --move in-progress
karr handoff 1 --claim "$NAME" --note "Ready for review" --timestamp
```

Protect yourself before destructive operations:

```bash
karr backup > karr-backup.yml
karr restore --yes < karr-backup.yml
karr destroy --yes
```

## karr-foundation: the agent coordinator

A board is half the tool. `karr-foundation` is the other half, and the reason
`karr` is not just a file kanban: a single-shot, idempotent companion binary
that watches **many** repositories, decides per board whether there is work,
and runs the configured agent command until the board stops moving. Point cron,
a systemd timer or a `while` loop at it — every tick is complete in itself.

```bash
*/5 * * * * karr-foundation           # a fleet on a cron line
```

Agent execution is **opt-in**, and both halves are useful on their own:

| You want | You run | You get |
|---|---|---|
| a picture of every board | `karr-foundation --status` | status counts, in-progress/blocked ids, lock, cooldown, agent state, open questions — read-only, no agent is ever started |
| agents to work the boards | `karr-foundation` | one agent per repository, per the `.karr` file in it or a fleet-wide `default_command` / `default_agent`. When no board resolves an agent command, this prints the overview instead |

Where the pieces live, and which of them travel:

| File or ref | Scope | Written by |
|---|---|---|
| `~/.config/karr-foundation/config.yml` | this machine (`--config` relocates it) | you |
| `<repo>/.karr` | this machine, this repo | you |
| `<repo>/.karr.state`, `.karr.lock`, `.karr.log` | this machine, this repo | foundation |
| `agents.state`, beside `config.yml` | this machine | foundation |
| `assignment.yml`, beside `config.yml` — which agents may work which repository, in order | this machine | the coordination agent (or you) |
| `refs/karr/config` → `foundation.enabled` | **the board — syncs** | `karr disable` / `karr enable` |
| `refs/karr-foundation/*` in the hub — the chain, its run logs, the question mailbox | **the fleet — syncs** | `karr-foundation chain` / `ask` / `answer` |

The four `<repo>` files are machine-local and belong in `.gitignore`. `karr
init` does not put them there — it only ignores the materialized file view
(`tasks/`, `config.yml`) — so add them yourself:

```gitignore
.karr
.karr.state
.karr.lock
.karr.log
```

Every transcript below is a real run of these commands; only repository paths
and the hostname are rewritten to readable ones.

### Case 1: one repository, one card per run

Start with nothing configured at all:

```console
$ karr-foundation
karr-foundation: config not found at /home/dev/.config/karr-foundation/config.yml — nothing to do
karr-foundation: no repos found — check config
$ echo $?
1
```

Name the repository. `dirs:` is the explicit list:

```yaml
# ~/.config/karr-foundation/config.yml
dirs:
  - /srv/webapp
```

That is already enough for the read-only half:

```console
$ karr-foundation --status
webapp
  3 tasks
  backlog:1  todo:2
```

A plain tick still does nothing, and says why:

```console
$ karr-foundation
No agent will run on any board. Showing overview (set 'command:', 'agent:' or 'claude: true' in a .karr file to enable agents; a board disabled with 'karr disable' never runs one).

webapp
  3 tasks
  backlog:1  todo:2
```

Now opt in, in the repository itself:

```yaml
# /srv/webapp/.karr
mode: ticket
command: my-agent --task "$KARR_TASK" --prompt "$PROMPT"
max_runtime: 1800
max_attempts: 2
```

`mode: ticket` is one agent run about **one card foundation names**. It picks
the card with `karr pick`'s own eligibility and ranking (not terminal, not
blocked, not held by a live claim; class, then priority, then id) and tells the
agent twice: as a closing sentence in `$PROMPT` naming the id, and as
`$KARR_TASK` for a template that wants the bare number. It does **not** claim
the card — the claim is the agent's work session (`karr agentname`), and the
board's `.karr.lock` already keeps everyone else out for the length of the run.

See what the next tick would do without doing it:

```console
$ karr-foundation --dry-run --verbose
sync --pull /srv/webapp
[2026-08-18T05:35:34] 1565842: TICKET task#1
[2026-08-18T05:35:34] 1565842: START command=my-agent --task "$KARR_TASK" --prompt "$PROMPT"
exec in /srv/webapp: my-agent --task "$KARR_TASK" --prompt "$PROMPT"
[2026-08-18T05:35:34] 1565842: DRY-RUN (skipped)
[2026-08-18T05:35:34] 1565842: STALL task#1 — no report from the agent
```

A dry run starts nothing and writes nothing — no agent, no `.karr.state`, no
`.karr.log`, and not even the pull the first line announces. It is also silent
without `--verbose`: those log lines are the verbose stream, not a report.

Then the real thing:

```console
$ karr-foundation --verbose
sync --pull /srv/webapp
[2026-08-18T05:35:34] 1565844: TICKET task#1
[2026-08-18T05:35:34] 1565844: START command=my-agent --task "$KARR_TASK" --prompt "$PROMPT"
exec in /srv/webapp: my-agent --task "$KARR_TASK" --prompt "$PROMPT"
working on #1 as fund-duty
[2026-08-18T05:35:35] 1565844: END elapsed=1s exit=0
```

The agent's own output is streamed to the terminal when there is one (or with
`--verbose`) and is always appended to `.karr.log`. The card moved, so nothing
else is said. `.karr.state` now carries the board fingerprint the next tick
compares against:

```json
{"hash":"e256a65404833f0e801b323e1e2301fd","last_exit":0,"last_run":"2026-08-18T05:35:35"}
```

### How a run is judged

After every agent run foundation classifies the outcome from what it can
observe — the run's own report where the agent emitted one, otherwise the exit
code, the board's ref movement and the captured output:

| Outcome | What it means | What follows |
|---|---|---|
| **progress** | the board moved (in `mode: ticket`: *this* card moved) | keep draining |
| **stall** | a card the agent engaged did not move | bump that card's attempt counter; at `max_attempts` auto-block it |
| **common-error** | the run's own report saying so, a non-zero exit, a timeout, or an error pattern in a run that moved nothing | no card is penalized; the repo goes into exponential cooldown |
| **idle** | the agent did nothing and grabbed nothing | stop |

A stall that repeats ends the loop rather than spinning on it. Here the same
agent ran twice and left its card where it was — only the tail of each tick
is shown:

```console
$ karr-foundation --force --verbose
...
I cannot make progress on #2
[2026-08-18T05:35:43] 1565933: END elapsed=0s exit=0
[2026-08-18T05:35:43] 1565933: STALL task#2 — no report from the agent

$ karr-foundation --force --verbose
...
I cannot make progress on #2
[2026-08-18T05:35:43] 1565937: END elapsed=0s exit=0
[2026-08-18T05:35:43] 1565937: STALL task#2 — no report from the agent
[2026-08-18T05:35:43] 1565937: AUTOBLOCK task#2: auto-block: no progress after 2 attempts (foundation)
```

The auto-block is a fallback, not a verdict: the agent may always set a better
reason itself with `karr edit --block`, and a card somebody else holds is never
blocked on foundation's say-so. Where there is no evidence that the agent
engaged a card at all — an agent that does not write through `karr` — nothing
is auto-blocked: a run that moved nothing and grabbed nothing ends the drain as
`idle` after one iteration, and a run that keeps moving the board while
foundation cannot attribute a card to it ends on the iteration cap.

`mode:` says what one pass over a repository is: `drain` (the default: run
again until the board stops moving), `single` (exactly one run, the agent picks
its own work) or `ticket` (one run, one named card).

### Case 2: a fleet — `scan:`, `concurrent:`, the hub

```yaml
# ~/.config/karr-foundation/config.yml
scan:
  - /srv                    # every direct subdir that is a board
concurrent: 3               # boards that may have an agent at once (default: 1)
hub: /srv/fleet-hub         # the repo carrying refs/karr-foundation/*
```

`scan:` takes the direct children of a directory that have a `.karr` file or
are karr boards themselves; `dirs:` names repositories explicitly. A repository
reachable both ways is processed once, not twice.

```console
$ karr-foundation --status
webapp
  3 tasks  [agent]
  backlog:1  todo:2

docs-site
  2 tasks  [agent]
  in-progress:1  todo:1
  in-progress: #2
```

`concurrent:` is a **machine ceiling**, not a quota. One agent per repository
stays the hard rule — two agents in one working tree would collide over the
index and the checkout — so concurrency is across repositories and never inside
one. Three limits bound what actually runs and **the tightest wins**: the
machine ceiling here, a `concurrent:` on a named agent definition (the
operator's estimate of a session limit), and the `limits:` block in the current
chain header. `--dry-run` stays serial whatever the ceiling says.

`hub:` names the one repository of a fleet that carries
`refs/karr-foundation/*` — the chain, its run logs and the question mailbox. An
ordinary tick pulls that namespace before it reads anything and writes nothing
back to it; executing the chain is a command of its own (case 5).

### Case 3: `on_drained` — the hook karr deliberately does not understand

When a board has drained — no actionable task left, everything done, archived
or blocked — foundation can run one command in it:

```yaml
# /srv/gate/.karr
command: my-agent --prompt "$PROMPT"
on_drained: ./release-gate.sh
on_drained_max_runtime: 1800
on_drained_max_rounds: 3
```

```console
$ karr-foundation --verbose
sync --pull /srv/gate
[2026-08-18T05:35:54] 1566032: START command=my-agent --prompt "$PROMPT"
exec in /srv/gate: my-agent --prompt "$PROMPT"
no card assigned, nothing to do
[2026-08-18T05:35:54] 1566032: END elapsed=0s exit=0
[2026-08-18T05:35:54] 1566032: START role=hook command=./release-gate.sh
exec in /srv/gate: ./release-gate.sh
release gate in /srv/gate (role=hook)
[2026-08-18T05:35:54] 1566032: END elapsed=0s exit=0
[2026-08-18T05:35:54] 1566032: ON-DRAINED exit=0
```

**karr does not know what that command does, and must not.** In the fleet this
design came from it is a release gate that builds a distribution, installs it,
tests every dependent against it and raises version requirements — across 44
distributions, none of which karr is allowed to learn a single thing about.
Everything domain-specific — what "done" means for a project, how a release is
verified, which project depends on which — reaches karr through `on_drained`
and through nothing else. So the exit code is written to `.karr.log` and
`.karr.state` and interpreted by nobody: a failing hook does not park the
board, does not mark its agent failing, and never becomes the run's
`last_error`. It is not an agent run and is not classified as one.

The hook is told where it is and nothing else: `KARR_REPO`, and `KARR_ROLE=hook`
so that its own `karr` writes land in their own activity log instead of counting
as an agent's engagement with a card. `PROMPT` and `KARR_TASK` are empty. It
runs in the board's directory, under the board's own `.karr.lock`, with its own
budget (`on_drained_max_runtime`) — how long an agent may take says nothing
about how long a release gate may.

An empty board is not the same as finished work: the hook may fail and file
tickets, the next tick works them, the board drains again and the hook is asked
again. That cycle is the point, so it is bounded rather than forbidden — the
same board is not asked twice (the fingerprint it last ran at is in
`.karr.state`), and consecutive rounds in which the hook itself made work are
capped by `on_drained_max_rounds` (default 3, `0` disables). `--force`
overrides both.

### Case 4: named agents, and what happens when one breaks

A board has one command. A fleet has several agent commands with different
strengths and different failure modes, so the config names them and a board
picks one:

```yaml
# ~/.config/karr-foundation/config.yml
agents:
  main:
    command: claude
    kind: claude-code         # karr appends -p "$PROMPT", output format, limits
    permission_mode: bypassPermissions
    max_turns: 30
    concurrent: 2
    probe_every: 15m
    description: >-
      Strong on refactors and tests. Expensive.
  cheap:
    command: my-small-agent --quiet
    probe_every: 5m
    description: >-
      Fine for copy edits and docs. Weak on multi-file changes.
default_agent: cheap
```

```yaml
# /srv/docs-site/.karr
agent: cheap
mode: drain
```

`kind: shell` (the default) means karr appends **nothing** — the command is a
complete shell template, because karr cannot know what the thing at the other
end understands. `kind: claude-code` is the one invocation contract it does
know: it appends `-p "$PROMPT"`, the `stream-json` output format, and
`--permission-mode`, `--max-turns` and `--allowed-tools` from the definition —
so permission escalation is a property of the agent definition rather than
something baked into a wrapper script. `description` is never read by karr; it is
carried for the agent that routes work across the fleet, and `--status
--verbose` prints it:

```console
$ karr-foundation --status --verbose
...
Agents
  cheap  ok
         kind: shell
         Fine for copy edits and docs. Weak on multi-file changes.
  main   ok
         kind: claude-code
         Strong on refactors and tests. Expensive.
```

Now let the agent break — a rate limit, an expired token, a missing binary; from
the outside they are the same event, so one mechanism covers all of them:

```console
$ karr-foundation --verbose
sync --pull refs/karr-foundation/*
sync --pull /srv/docs-site
[2026-08-18T05:36:04] 1579195: START agent=cheap command=my-small-agent --quiet
exec in /srv/docs-site: my-small-agent --quiet
API error: 429 Too Many Requests
[2026-08-18T05:36:04] 1579195: END elapsed=0s exit=1
[2026-08-18T05:36:04] 1579195: COMMON-ERROR exit=1
cooldown /srv/docs-site — 1m (level 1)
```

Two records, one level apart. The **board** cools down, in `.karr.state`:

```json
{"cooldown_level":1,"cooldown_until":1787031424,"hash":"06f46bec5e62ca7d8cddafac75eb8299","last_error":"exit=1","last_exit":1,"last_run":"2026-08-18T05:36:04"}
```

and the **agent** is marked failing, in `agents.state` beside the config file:

```json
{"cheap":{"failing_since":1787031364,"last_error":"exit=1","next_attempt":1787031664,"state":"failing"}}
```

That second record is the one that scales: while an agent is failing, **every**
board that uses it is skipped, because the fact is about the command and this
machine, not about a repository. Two boards on one agent share the outage
instead of each burning a window rediscovering it. Both are visible:

```console
$ karr-foundation --status
docs-site
  2 tasks  [cooldown 60s (exit=1), agent:cheap failing]
  in-progress:1  todo:1
  in-progress: #2

Agents
  cheap  failing since 2026-08-18T05:36:04, next attempt at 2026-08-18T05:41:04 (exit=1)
  main   ok
```

and the next tick simply says so and moves on:

```console
$ karr-foundation --verbose
sync --pull refs/karr-foundation/*
skip /srv/docs-site — in cooldown for 59s
```

Neither wait is overridden by `--force`, and neither needs an operator: the
cooldown grows `cooldown_base × 2^level` minutes up to `cooldown_max` and resets
on the next clean run, and the agent is retried after `probe_every` — the probe
**is** the next run, on the work that was waiting. karr keeps no cost, token or
quota model; it keeps `ok`, or `failing since X, next attempt at Y`, plus a
bounded record of past recoveries so a rhythm can be read out of it later.
Reading that rhythm is a coordination agent's job, never a learning algorithm
inside karr.

`agents.state` is deliberately not board state and not per repository: an agent
command that exists on one machine does not exist on the next, and a spent
account limit is a property of a person, not of a project.

Which agent works which board is the other half of a fleet with several of them,
and it is not something to write into every `.karr` by hand. Two config keys and
one file cover it. First, mark the agent that does the routing — the fleet's
**judgement layer**, an ordinary definition with a `role`:

```yaml
# ~/.config/karr-foundation/config.yml (same file as above)
agents:
  planner:
    command: claude
    kind: claude-code
    role: coordinator       # exactly one agent may carry this
    description: >-
      Plans and routes. Called only when a plan is missing or has broken.

routing: >-                 # prose, never parsed by karr
  cheap does the routine work and the docs. main is for refactors and
  anything touching a release. If main is down, wait rather than hand a
  release to cheap.
```

`routing:` is the operator's own prose about how they want their agents used,
and it goes into the coordination agent's prompt verbatim: the thing choosing is
a language model, so there are no classes and no enums here either.

What that agent writes is `assignment.yml`, beside `config.yml` — repository
path to an ordered list of agents, with an explicit `WAIT` for "rather wait than
use anything further down". It is asked only for a board that has not already
said what it wants, so the two boards it routes have to stop saying it:
`/srv/webapp` gives up the literal `command:` from case 1 and `/srv/docs-site`
the `agent:` line above, and both keep their `mode:`.

```yaml
# /srv/webapp/.karr
mode: ticket
max_runtime: 1800
max_attempts: 2
```

```yaml
# /srv/docs-site/.karr
mode: drain
```

```yaml
# ~/.config/karr-foundation/assignment.yml
repos:
  /srv/docs-site:
    - cheap
    - main
  /srv/webapp:
    - main
    - WAIT
```

From there routing needs no AI at all: foundation looks the repository up and
takes the first entry that currently works. A board whose chain reaches `WAIT`,
or whose agents are all failing, runs nothing this tick and says so —
`agent-waiting` in the overview with the reason under it, because an agent board
whose agents are down and a board nobody configured an agent for are fixed by
different things. Let `main` go the way `cheap` went — a second rate limit, a
second dead key — and `/srv/webapp` waits instead of falling through to
something the operator ruled out:

```console
$ karr-foundation --status
webapp
  3 tasks  [agent-waiting]
  backlog:1  todo:2
  waiting:     the assignment says WAIT for this board (after main, which is failing)
```

The assignment sits below anything a board says about itself — its own
`command:` or its own `agent:`, which is why both boards had to give theirs up:
a board that names one has said the most specific thing there is to say about
itself. It sits above `default_agent`, which is per fleet where this is per
repository. Like the definitions it names, it is local and never in refs, and
you can write it by hand: it is a plain routing table, not a cache.

### Case 5: the chain — write a plan, run it, read the run log

`karr-foundation chain` is the VM of "the AI is the compiler, the chain is the
program": the chain lives in the hub as a DAG of steps, and the executor takes
what the plan says is ready, checks each precheck against facts it measures off
the boards, runs it, and writes the state and the run log back.

A chain is written into `refs/karr-foundation/chain/*` — with a schema, a cycle
check and compare-and-swap updates, which is why `karr set-refs` refuses that
namespace outright. `karr-foundation plan` is the way in: one YAML document on
stdin (JSON goes through the same parser), and it replaces the chain that is
there.

```bash
karr-foundation plan <<'CHAIN'
steps:
  - id: docs
    kind: shell
    repo: /srv/docs-site
    command: ./build-docs.sh
    precheck: board_actionable == yes
  - id: smoke
    kind: shell
    repo: /srv/webapp
    command: ./smoke-test.sh
  - id: registry
    kind: question
    needs: [ docs, smoke ]
  - id: publish
    kind: shell
    repo: /srv/webapp
    needs: [ registry ]
    command: ./publish.sh
limits:
  concurrent: 4
note: release 0.6
CHAIN
```

`--dry-run` checks a chain and writes nothing; `--input PATH` reads it from a
file instead of stdin. The whole document is validated before the first ref is
written, so a chain karr will not take leaves the one in the hub untouched, and
a chain that still has a step *running* is refused unless you pass `--force`.
It replaces rather than appends because that is what the header means: only
steps whose chain id matches it are ever ready. The Perl API underneath
(`App::karr::Foundation::ChainStore->write_chain`) is the same path and is
still there — it just is no longer the only one, which used to mean the
coordination agent got a `perl -e` one-liner in its prompt where everything
else it does is a command.

A step names an id, a `kind`, and the steps it `needs`; steps with no edge
between them may run at once. It may **not** name an agent: the chain is shared
state and an agent is a property of a machine, so that is refused rather than
ignored. The four kinds:

| Kind | What it is |
|---|---|
| `ticket` | one card through the target repo's **ticket mode** (case 1) — the lock, the claim discipline, the ownership guard and the run's own report all come from there, not from a second copy here |
| `shell` | a command in the repo, under that repo's own `.karr.lock`, with `KARR_ROLE=chain` |
| `question` | waits on the mailbox (below) |
| `plan` | recognised, left pending, planner recorded as wanted — see "What is built" |

A `precheck` is the condition the planner assumed, in the grammar
`<fact> == <value>` (or `!=`). The facts are `board_actionable`,
`ticket_status`, `ticket_blocked`, `ticket_claimed`, `ticket_links` and — for a
question step only, measured off the mailbox rather than a board —
`question_state` (`answered`, `open` or `overdue`). A fact that cannot be
measured is **absent**: a repository this machine does not have, a card that is
not on the board, a question step nothing in the mailbox names. An absent fact
makes the precheck not hold whichever operator it uses — every uncertainty
falls to the side that costs a planning round rather than the side that runs
the wrong thing.

`ticket_links` is the one measured off **another** board: the cross-board links
(`needs:BOARD#ID`) the step's card carries. It is `settled` when every one of
them is in one of the *far* board's own terminal statuses — and for a card
carrying no link at all, so a precheck keeps holding once `karr needs
--resolve` has settled the link and dropped the tag. Otherwise it reports the
first unsettled link in tag order, `open` or `missing`; a far card that does
not exist settles nothing. A link naming a board this machine does not hold
makes the fact absent, so the step goes stale here and the machine that has
that board runs it. The far board is read as it stands in that working copy —
nothing is fetched — and the block on the near card is **not** lifted when the
last link settles: the link is the fact, `blocked` is the decision, and lifting
it is still `karr needs --resolve`.

The question a chain waits on is asked by whoever wrote the plan, not by the
step — a step that asked its own question would have to carry the question text,
its options, its policy, its default and its deadline, which is the mailbox's
schema written out a second time:

```console
$ karr-foundation ask "Which registry does 0.6 go to?" --options cpan,darkpan --step registry
Asked question #1: Which registry does 0.6 go to?
  answer with: karr-foundation answer 1 <cpan|darkpan>
  nobody answers: block
```

Look before you leap — a dry run pulls nothing, claims nothing and executes
nothing:

```console
$ karr-foundation chain --dry-run
chain 20260818T053250Z-18641c: 2 step(s) ready (dry run, nothing pulled, claimed or executed)
  step docs (shell) in /srv/docs-site: would run
  step smoke (shell) in /srv/webapp: would run
```

Then run it:

```console
$ karr-foundation chain
step docs (shell) in /srv/docs-site: done — exit=0
step smoke (shell) in /srv/webapp: done — exit=0
step registry (question): left pending — question #1 is unanswered (policy: block)
chain 20260818T053250Z-18641c: 2 done, 1 pending
```

Waiting never holds the tick up: the question step is considered once, said out
loud and left — **pending and unclaimed**, with no attempt counted and no
started stamp, so the next tick finds it exactly as the planner left it. Its
dependents wait by construction (a step becomes ready only when everything it
`needs` is `done`) and every other branch runs in the same tick. Answer it, and
the next tick walks on:

```console
$ karr-foundation answer 1 darkpan
Answered question #1: darkpan
  Which registry does 0.6 go to?

$ karr-foundation chain
step registry (question): done — question #1 answered 'darkpan' by Dev <dev@example.com>
step publish (shell) in /srv/webapp: done — exit=0
chain 20260818T053250Z-18641c: 2 done
```

What a question step does is the mailbox's state plus the policy the asker wrote
down for the case where nobody answers:

| Mailbox state | The step |
|---|---|
| `answered` | **done**, with the answer in the run log |
| `open` | **pending and unclaimed** — dependents wait, every other branch runs |
| `overdue` + `block` | keeps waiting: waiting *is* what `block` means |
| `overdue` + `use_default` | **done**, with the `--default` as the answer |
| `overdue` + `escalate_to_ai` | pending, and handed to the coordination agent at the end of the tick where the fleet marks one — the step is never answered on that agent's behalf |
| nothing in the mailbox names the step | **`stale`** — a planning error, reported as one |

Asked with `--policy use_default` and a `--default`, a deadline that passes
therefore settles the step without anybody typing anything — here the whole
chain finishes in one tick:

```console
$ karr-foundation chain
step docs (shell) in /srv/docs-site: done — exit=0
step smoke (shell) in /srv/webapp: done — exit=0
step registry (question): done — question #1 went unanswered past its deadline; its default 'cpan' stands as the answer
step publish (shell) in /srv/webapp: done — exit=0
chain 20260818T053024Z-e7bc10: 4 done
```

and a ready question step nothing in the mailbox names is **not** left waiting
quietly for a question that is never going to arrive:

```console
$ karr-foundation chain
step docs (shell) in /srv/docs-site: done — exit=0
step smoke (shell) in /srv/webapp: done — exit=0
step registry (question): stale — no question in the mailbox names step registry — a question step is asked by the planner ('karr-foundation ask ... --step registry'), it does not ask itself
chain 20260818T052941Z-acdde8: 2 done, 1 stale
the planner is wanted for step(s) registry (no question was ever asked about it) — the coordination agent is called at the end of this tick
calling the coordination agent 'planner' for 1 deviation(s): step registry: no question was ever asked about it
the coordination agent 'planner' finished (success); the next tick runs what it wrote
```

A step waits until **every** question naming it is settled; a question whose
step is not ready yet is simply not looked at, which is the good case — it can
be answered long before the step arrives, and then the step never waits at all.
One limit is worth knowing: a question names a **step id and nothing else**, so
a later chain that reuses an id inherits whatever the earlier one left
unanswered under it. Answer or delete a question the fleet has stopped caring
about.

A step whose precheck no longer holds is **not** executed: it is marked `stale`
and the planner is recorded as wanted — and called, where the fleet marks a
coordination agent (see below). A step that fails stops its own branch
and nothing else. A rate-limited agent, a locked or disabled board and a
repository this machine does not have are requeues, not failures — none of them
is a statement about the plan.

The run log is one ref per run, in the hub, and reading it is what `get-refs` is
for:

```console
$ cd /srv/fleet-hub
$ git for-each-ref --format='%(refname)' refs/karr-foundation/log/
refs/karr-foundation/log/2026-08-18-053250a33ef5
refs/karr-foundation/log/2026-08-18-0532510c55f1

$ karr get-refs refs/karr-foundation/log/2026-08-18-053250a33ef5
{"chain":"20260818T053250Z-18641c","event":"start","host":"fleet-01","pid":1563039,"ts":"2026-08-18T05:32:50Z"}
{"event":"step","kind":"shell","repo":"/srv/docs-site","state":"running","step":"docs","ts":"2026-08-18T05:32:50Z"}
{"detail":"exit=0","event":"step","state":"done","step":"docs","ts":"2026-08-18T05:32:50Z"}
{"event":"step","kind":"shell","repo":"/srv/webapp","state":"running","step":"smoke","ts":"2026-08-18T05:32:50Z"}
{"detail":"exit=0","event":"step","state":"done","step":"smoke","ts":"2026-08-18T05:32:50Z"}
{"detail":"question #1 is unanswered (policy: block)","event":"step","kind":"question","state":"pending","step":"registry","ts":"2026-08-18T05:32:50Z"}
{"chain":"20260818T053250Z-18641c","done":2,"event":"end","pending":1,"ts":"2026-08-18T05:32:50Z"}
```

The waiting step has a `pending` entry and no `running` one before it — nothing
was claimed and nothing was started. Run logs are segmented and pruned by
themselves (14 days, 500 runs).

`chain` is a command rather than something a plain tick does on the side: a cron
entry written before the fleet had a chain must not start doing something else
the day somebody writes one.

### Case 6: the question mailbox

A question is a file with an answer field, not a dialogue — which is what
removes the special case for "a human happens to be present". `ask` writes one
into the hub and returns; whoever answers needs to know nothing about the chain:

```console
$ karr-foundation ask "Which registry do we publish the 0.6 release to?" \
    --context "the release gate is waiting" \
    --options cpan,darkpan --default cpan --policy use_default --wait 3600
Asked question #1: Which registry do we publish the 0.6 release to?
  answer with: karr-foundation answer 1 <cpan|darkpan>
  nobody answers: use_default after 2026-08-18T06:37:44Z
```

Open questions show up in the overview, with the id `answer` takes:

```console
$ karr-foundation --status
...
Open questions
  #1  Which registry do we publish the 0.6 release to?
      options: cpan, darkpan  use_default after 2026-08-18T06:37:44Z
```

```console
$ karr-foundation answer 1 darkpan --note "this one is a private release"
Answered question #1: darkpan
  Which registry do we publish the 0.6 release to?
```

`--policy` is what happens when nobody answers:

| Policy | With `--wait` elapsed |
|---|---|
| `block` (default) | keep waiting — that is what blocking means |
| `use_default` | `--default` becomes the answer |
| `escalate_to_ai` | handed to the coordination agent at the end of the tick, where the fleet marks one; recorded and left waiting where it does not |

An answer is create-only and is validated against the options it was offered, so
two answers cannot silently become one; `--force` on `answer` is what replaces
one deliberately. Both commands sync the fleet namespace around what they write.
`--step ID` is what binds a question to a chain step.

### The board's own opt-out

A board can refuse automated runs **in its own karr state**, which is what a
fleet-wide `default_command` otherwise makes impossible:

```console
$ karr disable --reason "docs freeze until the 0.6 release"
Board disabled for automated agent runs (karr-foundation).
  Reason: docs freeze until the 0.6 release

$ karr-foundation --status
docs-site
  2 tasks  [disabled]
  in-progress:1  todo:1
  disabled:    docs freeze until the 0.6 release
  in-progress: #2

$ karr enable
Board enabled for automated agent runs (karr-foundation).
```

Unlike `.karr`, this is board state (`foundation.enabled` in `refs/karr/config`),
so it syncs and every foundation instance on every machine honours it. A
disabled board is skipped **whole**: the flag is checked before the agent
command is resolved and before the drain decision, so there is no drain, no
auto-block and no agent run. It wins over `--command`, `default_command`, the
`.karr` `command`, a named `agent`, the assignment, `default_agent` and
`claude: true`, and `--force` does *not* override it. The
same state is readable and settable through `karr config get` / `karr config
set` (`foundation.enabled`, `foundation.reason`).

### What is built, and what is not

The design has three layers: **coordination** — shared and synced, the tickets,
the chain, the questions, the run log; **execution** — local and never in a
repository, which agent commands exist here, whether they work, how many may run
at once; and **judgement** — an agent that plans and routes, invoked only when a
written plan is missing or has broken. karr owns the first two outright and
calls the third: a fleet that marks one of its agents `role: coordinator` gets
one call per tick carrying every deviation that tick met, and a fleet that marks
none gets what this always was — for the chain's own deviations, "the planner is
wanted" as a line of output, with the operator as the planner.

| Piece | State |
|---|---|
| overview, discovery, drain/single/ticket modes, cooldown, stall detection, auto-block | built |
| `disable` / `enable`, per-repo lock and state, concurrency, `on_drained` | built |
| named agents, `kind: claude-code`, availability probing, `agents.state` | built |
| the question mailbox: `ask`, `answer`, `--status` listing, policies | built |
| `chain` with `kind: ticket`, `kind: shell` and `kind: question` steps, prechecks, run logs | built |
| `kind: question` resolving the mailbox | built — pending and unclaimed while the answer is `open`, done once it is there, the default taken on `use_default`, `stale` when nothing in the mailbox names the step |
| `kind: plan` steps | **still not executed** — recognised and left pending, because a plan step asks for a new plan and the executor executes plans. It is one of the four deviations that call the coordination agent |
| the coordination agent / planner | built — `role: coordinator` on an agent definition, called once at the end of a tick for the deviations it met, writing the assignment, chains and questions |
| routing: the assignment (`assignment.yml`) | built — repository to an ordered agent list with `WAIT`; looked up in the hot path, no AI in it |
| writing a chain from the CLI | not built — a chain is written through `App::karr::Foundation::ChainStore`, which is also how the coordination agent is told to write one |
| `escalate_to_ai` | handed to the coordination agent where one is marked; recorded and left waiting where none is |
| cross-board links in a chain | built — the `ticket_links` fact measures the far cards for a precheck (`settled` / `open` / `missing`); resolving stays with `karr needs --resolve` |

Where the design says "call the planner", foundation records that the planner is
wanted and says so at the end of the tick. With no `role: coordinator` in the
config that is the whole of it — nothing is written that a planner would have to
undo, and no agent is invented to fill the gap:

```console
$ karr-foundation chain
step smoke (shell) in /srv/webapp: done — exit=0
step replan (plan): left pending — this foundation runs kind: ticket, kind: shell and kind: question
chain 20260818T053131Z-c075f7: 1 done, 1 skipped
the planner is wanted for step(s) replan (kind: plan is not executed here) — no planner runs from here yet; re-plan the chain
```

With one marked, the same tick ends by calling it — once, after everything else
it could do, and with every deviation it met:

```console
$ karr-foundation chain
step smoke (shell) in /srv/webapp: done — exit=0
step replan (plan): left pending — this foundation runs kind: ticket, kind: shell and kind: question
chain 20260818T053131Z-c075f7: 1 done, 1 skipped
the planner is wanted for step(s) replan (kind: plan is not executed here) — the coordination agent is called at the end of this tick
calling the coordination agent 'planner' for 1 deviation(s): step replan: kind: plan is not executed here
the coordination agent 'planner' finished (success); the next tick runs what it wrote
```

The four deviations are a `kind: plan` step, an `escalate_to_ai` question past
its deadline, a step gone `stale`, and a repository the assignment cannot route.
The run happens in the hub, under the hub's own `.karr.lock`, with
`KARR_ROLE=coordinator`; while that agent is itself failing it is not called and
the deviation waits, exactly as a board waits for its own agent. Nothing is
re-read afterwards — what it wrote is what the **next** tick runs.

### Reference

`karr-foundation` options:

| Option | Effect |
|---|---|
| `--config PATH` | config file (default `~/.config/karr-foundation/config.yml`); also relocates `agents.state` and `assignment.yml` |
| `--status` | read-only overview of every board, then exit |
| `--dry-run` | decide everything, execute nothing (serial, and silent without `--verbose`) |
| `--verbose` | log lines and agent output on the terminal, agent descriptions in `--status` |
| `--force` | run regardless of board state; on `answer`, replace an existing answer |
| `--command CMD` | one agent command for every board, overriding each `.karr` |
| `ask` / `answer` / `chain` | the hub commands (`--context`, `--options`, `--default`, `--policy`, `--wait`, `--step`; `--note`) |

Exit codes follow the same contract as `karr`: `0` the tick finished, `1` a
runtime failure (no repos, unparsable config, a hub command with no hub), `2` a
usage error. A chain step that *failed* does not change the exit code — that is
a statement about the plan, not about the binary.

`config.yml` keys:

| Key | Meaning |
|---|---|
| `dirs:` | explicit board repositories |
| `scan:` | parent directories whose direct children are checked for a board |
| `concurrent:` | machine ceiling of boards with an agent at once (default 1) |
| `hub:` | the repository carrying `refs/karr-foundation/*` |
| `agents:` / `default_agent:` / `probe_every:` | named agent definitions, the fallback board agent, the default retry interval |
| `role: coordinator` on one definition | marks the fleet's judgement layer; exactly one may carry it |
| `routing:` | the operator's prose about how their agents should be used, handed to the coordination agent verbatim |
| `default_command:` / `default_prompt:` | fleet-wide command and prompt |
| `mode:`, `claude:`, `claude_bin:`, `claude_max_turns:`, `claude_permission_mode:`, `on_drained:`, `on_drained_max_runtime:`, `on_drained_max_rounds:` | fleet-wide defaults for the `.karr` keys of the same name |

`.karr` keys, per repository (where a fleet-wide default of the same name
exists, the `.karr` value wins; the rest exist only per repository):

| Key | Meaning |
|---|---|
| `command:` | the agent command; a shell template, `$PROMPT` and `$KARR_TASK` exported into it |
| `prompt:` | the instruction handed over as `$PROMPT` |
| `agent:` | a named agent from `agents:` |
| `claude:` / `claude_bin:` / `claude_max_turns:` / `claude_permission_mode:` | synthesize the canonical claude command (opt-in) |
| `mode:` | `drain` (default), `single`, `ticket`; `drain: true\|false` is the older spelling of the first two |
| `on_idle:` | `skip` (default) or `always-run` |
| `max_runtime:` | per-command timeout in seconds — TERM to the process group, KILL two seconds later (`0` = no timeout) |
| `max_attempts:` | stalls on one card before it is auto-blocked (default 2) |
| `max_iterations:` | hard cap on drain iterations (default 50) |
| `cooldown_base:` / `cooldown_max:` | cooldown minutes at level 0 (default 1) and the ceiling (default 64) |
| `error_patterns:` | extra case-insensitive substrings that count as a common error |
| `on_drained:` / `on_drained_max_runtime:` / `on_drained_max_rounds:` | the domain hook, its budget and its round cap |

Command resolution order, highest first: `--command`, `default_command`, the
`.karr` `command`, the `.karr` `agent`, the **assignment** (`assignment.yml`,
asked only for a board that names no agent of its own), `default_agent`,
`claude: true`. A board disabled with `karr disable` runs none of them, and a
board whose assignment entry says `WAIT` — or whose agents are all failing —
runs nothing this tick either.

Full detail: `perldoc App::karr::Foundation`, and for the chain
`perldoc App::karr::Foundation::Executor`,
`perldoc App::karr::Foundation::ChainStore`,
`perldoc App::karr::Foundation::Questions`,
`perldoc App::karr::Foundation::Agents`,
`perldoc App::karr::Foundation::Coordinator`.

## Run the examples yourself: the `ex/` sandbox

Every transcript above is a real run; the `ex/` directory turns that claim into
something you can verify in minutes. `ex/setup.sh` builds two sample
repositories (`webapp`, `docs-site`) with seeded boards, wires them into one
`karr-foundation` fleet with a hub and a demo chain, and ships demo agents —
ticket mode, drain mode, a lazy agent that stalls, and one that fails with an
API error for the cooldown case. Everything runs on one machine with no server,
no remote and no credentials:

```bash
./ex/setup.sh --reset
perl -Ilib bin/karr-foundation --config ex/config.yml --status
perl -Ilib bin/karr-foundation --config ex/config.yml
```

`ex/README.md` is the full guide — build the sandbox, run each scenario, and
exercise the chain (`karr-foundation chain` / `ask` / `answer`) against a real
setup.

## Installation

### Perl

```bash
cpanm App::karr
```

### Docker

The published images are:

- `raudssus/karr:latest`
- `raudssus/karr:user`

`latest` is the ergonomic default. It starts as root only long enough to inspect
`/work`, then drops to the owner of the mounted workspace before running
`karr`. That keeps host files from becoming root-owned.

`user` is the fixed-user image. It defaults to `1000:1000` and is the better
base when you want a deterministic downstream derivative.

Minimal smoke test:

```bash
docker run --rm -it -w /work -v "$(pwd):/work" raudssus/karr:latest --help
```

Recommended alias for real use:

```bash
alias karr='docker run --rm -it \
  -w /work \
  -e HOME=/home/karr \
  -v "$(pwd):/work" \
  -v "$HOME/.gitconfig:/home/karr/.gitconfig:ro" \
  -v "$HOME/.ssh:/home/karr/.ssh:ro" \
  -v "$HOME/.claude:/home/karr/.claude" \
  -v "$HOME/.codex:/home/karr/.codex" \
  -v "$HOME/.cursor:/home/karr/.cursor" \
  raudssus/karr:latest'
```

The `.ssh` mount is what makes an `ssh://` remote work at all. `HOME` inside
the container is `/home/karr`, so that is where both libgit2 and `ssh` look for
`known_hosts` and for keys — without the mount they find neither, and karr
reports the host as unknown no matter how often you run `ssh-keyscan` on the
host. It is mounted read-only so a container can never rewrite your keys.

One caveat with mounting the whole directory: the image ships a current
OpenSSH, and a `~/.ssh/config` written against an older one can be refused
outright — `Bad key types '+ssh-dss'`, and the connection never starts. Set
`GIT_SSH_COMMAND="ssh -F /dev/null -o UserKnownHostsFile=/home/karr/.ssh/known_hosts"`
to skip the config and keep the host keys.

If your key needs a passphrase, forward the agent instead of relying on the key
files. That does not belong in an alias, because `docker run` rejects the mount
outright when no agent is running:

```bash
karr() {
  local ssh_agent=()
  [ -n "$SSH_AUTH_SOCK" ] && ssh_agent=(-v "$SSH_AUTH_SOCK:$SSH_AUTH_SOCK" -e SSH_AUTH_SOCK)
  docker run --rm -it -w /work -e HOME=/home/karr \
    -v "$(pwd):/work" \
    -v "$HOME/.gitconfig:/home/karr/.gitconfig:ro" \
    -v "$HOME/.ssh:/home/karr/.ssh:ro" \
    "${ssh_agent[@]}" raudssus/karr:latest "$@"
}
```

With that alias, all normal commands stay identical:

```bash
karr init --name "HandyIntelligence Prototype" --claude-skill
karr skill install --agent codex --global --force
karr create "Document release workflow"
```

If you want a custom fixed-user image in CI or a downstream repo, build from a
built distribution rather than from a git checkout. The `builder` stage installs
the tree with `cpanm`, and `Makefile.PL` only exists once Dist::Zilla has
generated it, so the repository root is not a usable build context.

```bash
cd App-karr-*/   # unpacked CPAN tarball, or `dzil build --no-tgz` in a clone

docker build --target runtime-user \
  --build-arg KARR_UID=1010 \
  --build-arg KARR_GID=1010 \
  -t raudssus/karr:user1010 .
```

Building both published images is what `dzil build` does anyway, via the
`[@Author::GETTY::Docker]` sections in `dist.ini`.

## How it works

The write path:

```text
pull refs -> change task/config -> push refs
```

Commands work directly against refs via `BoardStore`. A materialized `tasks/`
view is generated on demand (see `karr materialize`) and is never committed —
it is always in `.gitignore`.

Important refs:

- `refs/karr/config` — sparse YAML config overrides
- `refs/karr/meta/next-id` — the next numeric task id
- `refs/karr/meta/board-id` and `refs/karr/meta/encoding` — board identity, and
  the encoding marker `karr repair` reads
- `refs/karr/tasks/<id>/data` — task Markdown plus frontmatter
- `refs/karr/log/<role>/<url-encoded-email>` — append-style JSON log lines, keyed
  by a role-qualified identity (role `user` or `agent`) so a human and an AI
  sharing one Git config stay distinct

## Command map

### Board lifecycle

| Command | Use it for |
|---------|------------|
| `karr init` | create the board in `refs/karr/*` |
| `karr config` | inspect and change merged board settings |
| `karr backup` | export the whole board as YAML |
| `karr restore --yes` | replace the board from a YAML snapshot |
| `karr destroy --yes` | remove the board completely |
| `karr sync` | explicitly pull/push board refs |
| `karr materialize` | write the `tasks/` file view from the refs |
| `karr import --yes` | read the file view back into the refs |
| `karr repair` | migrate a 0.402-or-earlier board off double-encoded UTF-8 |
| `karr disable` / `karr enable` | opt this board out of (or back into) automated agent runs |

### Task lifecycle

| Command | Use it for |
|---------|------------|
| `karr create` | create a task |
| `karr list` | filter, search and sort tasks — finished work (the board's last status plus `archived`) is hidden unless you ask for it with `--status` or `--archived` |
| `karr show` | inspect one task in full (or `--me` / `--last N` / `--agent NAME` for recent) |
| `karr edit` | update body, metadata, claim, or blocked state |
| `karr move` | change status explicitly or with `--next` / `--prev` |
| `karr archive` | soft-delete into `archived` |
| `karr delete --yes` | permanently remove the task ref (prompts without `--yes`, and refuses with exit 1 when stdin is not a terminal) |

### Flow and coordination

| Command | Use it for |
|---------|------------|
| `karr board` | grouped board view (Done is hidden unless `--done`; bare `karr --done` does the same for the default view) |
| `karr dashboard` | multi-column, colour-coded overview of every karr board found by recursively searching a directory tree — configuration-free, unlike `karr-foundation --status` (`--depth`, `--hide-no-board` / `--show-no-board`) |
| `karr pick` | atomic next-task selection with claim |
| `karr unlock` | show or break pick locks left behind by a crashed agent |
| `karr handoff` | move into review and append a note |
| `karr needs` | report or resolve cross-board dependencies (`BOARD#ID` in another repository) |
| `karr context` | generate agent-facing board summary |
| `karr log` | inspect per-agent or per-task activity |
| `karr metrics` | throughput, lead/cycle time, flow efficiency off the cards' lifecycle stamps |
| `karr agentname` | generate short claim names (a new one every call - capture it once, see below) |

### Skills and helper refs

| Command | Use it for |
|---------|------------|
| `karr skill install` | install bundled skills for Claude Code, Codex, or Cursor |
| `karr skill check` | detect outdated installed skills |
| `karr skill update` | refresh installed skills |
| `karr skill show` | print the bundled skill to stdout |
| `karr set-refs` | store shared non-task payloads in allowed refs |
| `karr get-refs` | fetch helper payloads back out |

### Output and exit codes

Every board command takes `--json` for machine-readable output and `--compact`
for terse one-line output. `karr list --json` emits the full card payload —
frontmatter plus body — so reading a whole set of tickets is one call rather
than one `karr show` per id.

The exit code is a stable contract, because karr's primary callers are agents
scripting the CLI (`docs/adr/0002-exit-code-contract.md`):

| Code | Meaning |
|---|---|
| `0` | success, including no-op successes such as re-archiving an archived task |
| `1` | runtime failure — task id not found, board missing, Git or sync failed, a destructive command refused for want of `--yes`, or a batch that committed partial work with at least one item failing |
| `2` | usage error — unknown command or option, invalid option value, surplus or missing positional argument |

Per-command options are not listed here; `karr --help`, `karr <cmd> --help` and
`perldoc karr` carry them in full.

## Multi-agent workflow

```bash
NAME=$(karr agentname)

# pick the best available task
karr pick --claim "$NAME" --status todo --move in-progress

# inspect board state
karr board
karr list --claimed-by "$NAME"

# hand off to review
karr handoff 1 --claim "$NAME" --note "Implementation complete" --timestamp

# inspect activity trail
karr log --agent "$NAME"

# re-orient: the task I most recently acted on
karr show --me
```

`pick` respects blocked state, claim timeout, and class-of-service ordering:

- `expedite`
- `fixed-date`
- `standard`
- `intangible`

Dependencies do not block. `depends_on` (same board) and `needs:BOARD#ID`
(another repository) are recorded and warned about — `pick` and `move` hand the
card over and say what is still outstanding. The one flag that keeps a card out
of `pick` is `blocked`, set deliberately with `karr edit --block`; `karr needs
--resolve` drops links whose far card reached a terminal status, and lifts the
block when the last one settles.

## Helper refs

Not all shared workflow state belongs in tasks. `karr` also supports arbitrary
non-protected refs outside `refs/karr/*`.

```bash
karr set-refs superpowers/spec/1234.md draft ready
karr set-refs superpowers/spec/1234.md < design.md    # multi-line payload
karr get-refs superpowers/spec/1234.md
```

The arguments after the ref are joined with a single space, so they are a
one-line payload. A document goes in on stdin instead: with no content argument
at all, `karr set-refs REF < file` stores the file verbatim and
`karr get-refs REF > file` gives it back unchanged.

Use this for:

- planning blobs
- generated specs
- agent scratch state
- workflow metadata you want synced through Git but not modeled as cards

Protected namespaces such as branches, tags, remotes, stash, `refs/karr/*` and
`refs/karr-local/*` (where `karr pick` keeps its process-local locks) are
blocked. `refs/karr-foundation/chain/*`, `.../log/*` and `.../questions/*` are
read-only for `set-refs` — karr-foundation writes those with a schema and
compare-and-swap — while `get-refs` reads them freely, which is how one looks
at a step, a run log or a question.

## Skills

The distribution ships a bundled agent skill, `kanban-issues-karr-cli`, that
can be installed locally in a repo (as
`.claude/skills/kanban-issues-karr-cli/SKILL.md`) or globally in the current
home directory. A project still holding the older `.claude/skills/karr/` keeps
it untouched — nothing removes it for you, so delete it after updating.

```bash
karr skill install
karr skill install --agent claude-code
karr skill install --agent codex --global --force
karr skill check --global
karr skill update
karr skill show
```

Supported targets:

- `claude-code`
- `codex`
- `cursor`

Project-local Claude installation during board setup:

```bash
karr init --name "My Project" --claude-skill
```

## Board snapshots and destructive operations

Backups are full YAML snapshots of `refs/karr/*`:

```bash
karr backup > karr-backup.yml
```

Restore is intentionally destructive:

```bash
karr restore --yes < karr-backup.yml
```

It deletes current `refs/karr/*` refs first and then replays the snapshot.

Full board removal is explicit too:

```bash
karr destroy --yes
```

If a remote exists, `restore` and `destroy` also prune the remote board state
to match.

## Stored task shape

Tasks live in `refs/karr/tasks/*/data`, but the payload itself is ordinary
Markdown with YAML frontmatter:

```markdown
---
claimed_at: 2026-03-12T10:05:00Z
claimed_by: agent-fox
class: standard
created: 2026-03-12T10:00:00Z
id: 1
priority: high
started: 2026-03-12T10:05:00Z
status: in-progress
title: Fix login bug
updated: 2026-03-12T10:05:00Z
---

Task description here.
```

Keys are written in alphabetical order, and the lifecycle stamps (`started`,
`claimed_at`, `completed`) appear once the card reaches that point — so a card
still sitting in `backlog` carries fewer keys than the one above.

That makes the format easy to inspect, script, and reuse from Perl code.

## Programmatic usage

`karr` is primarily a CLI, but the lower-level modules are usable from Perl:

```perl
use App::karr::Git;
use App::karr::BoardStore;

my $git   = App::karr::Git->new(dir => '.');
my $store = App::karr::BoardStore->new(git => $git);

my $config = $store->effective_config;
my @tasks  = $store->load_tasks;
```

Or create a task directly:

```perl
use App::karr::Task;

my $task = App::karr::Task->new(
  id       => $store->allocate_next_id,
  title    => 'Write release notes',
  status   => 'backlog',
  priority => 'high',
);

$store->save_task($task);
$git->push;
```

## Why Docker matters here

Perl installation is the normal local path, but Docker is equally valid when a
downstream repo wants to vendor `karr` instead of adding a direct Perl tool
dependency. That keeps the command surface identical across:

- local Perl installs
- Codex/Claude/Cursor-heavy repos
- CI or ops environments that prefer containerized tooling

## License

This is free software, licensed under the Artistic License 2.0. See the
`LICENSE` file for the full text.
