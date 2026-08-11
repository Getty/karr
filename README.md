# App::karr

Git-native kanban for shared helper agents, human operators, and downstream
repos that want a board without checking a board directory into the work tree.

`karr` keeps canonical state in `refs/karr/*`, not in commits, branches, or a
persistent `karr/` folder. Tasks, config, logs, snapshots, and helper refs move
through normal Git transport, which makes the tool fit naturally into AI-heavy
and multi-machine workflows.

## Why it exists

Most task tools assume a central web service or a checked-in file tree.
`karr` takes a different route:

- board state lives in Git refs
- mutating commands pull, materialize, write back, and push
- tasks stay separate from branches and commits
- downstream projects can vendor the CLI through Docker and keep the exact same UX

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
karr pick --claim "$NAME" --status todo --move in-progress
karr handoff 1 --claim "$NAME" --note "Ready for review" --timestamp
```

Protect yourself before destructive operations:

```bash
karr backup > karr-backup.yml
karr restore --yes < karr-backup.yml
karr destroy --yes
```

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

Commands work directly against refs via C<BoardStore>. A materialized F<tasks/> view is generated on demand (see C<karr materialize>) and is never committed — it is always in F<.gitignore>.

Important refs:

- C<refs/karr/config> holds sparse YAML config overrides
- C<refs/karr/meta/next-id> holds the next numeric task id
- C<refs/karr/tasks/E<lt>idE<gt>/data> holds task Markdown plus frontmatter
- C<refs/karr/log/E<lt>roleE<gt>/E<lt>emailE<gt>> holds append-style JSON log lines, keyed by a role-qualified identity (role C<user> or C<agent>) so a human and an AI sharing one Git config stay distinct

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
| `karr disable` / `karr enable` | opt this board out of (or back into) automated agent runs |

### Task lifecycle

| Command | Use it for |
|---------|------------|
| `karr create` | create a task |
| `karr list` | filter and search tasks |
| `karr show` | inspect one task in full (or `--me` / `--last N` / `--agent NAME` for recent) |
| `karr edit` | update body, metadata, claim, or blocked state |
| `karr move` | change status explicitly or with `--next` / `--prev` |
| `karr archive` | soft-delete into `archived` |
| `karr delete` | permanently remove the task ref |

### Flow and coordination

| Command | Use it for |
|---------|------------|
| `karr board` | grouped board view |
| `karr pick` | atomic next-task selection with claim |
| `karr unlock` | show or break pick locks left behind by a crashed agent |
| `karr handoff` | move into review and append a note |
| `karr context` | generate agent-facing board summary |
| `karr log` | inspect per-agent or per-task activity |
| `karr agentname` | generate short claim names |

### Skills and helper refs

| Command | Use it for |
|---------|------------|
| `karr skill install` | install bundled skills for Claude Code, Codex, or Cursor |
| `karr skill check` | detect outdated installed skills |
| `karr skill update` | refresh installed skills |
| `karr set-refs` | store shared non-task payloads in allowed refs |
| `karr get-refs` | fetch helper payloads back out |

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

## Automated execution: karr-foundation

`karr-foundation` is a single-shot, idempotent companion binary — a multi-board
**coordinator**. Point cron (or a systemd timer, or a tight loop) at it and it
scans configured repos, decides whether there is work, and **drains** each
board — running the configured agent command repeatedly until no actionable
task remains.

Agent execution is opt-in. When no board has an agent configured, the default
action is a read-only **overview** of every board (status counts,
in-progress/blocked tasks, lock and cooldown state) — so a human can use
foundation purely to coordinate their own work, with no AI involved.

```bash
# every 5 minutes
*/5 * * * * karr-foundation

karr-foundation --force            # run regardless of board state
karr-foundation --dry-run --verbose
karr-foundation --status           # read-only overview of every board, no runs
```

It reads `~/.config/karr-foundation/config.yml` (or `--config`):

```yaml
dirs:
  - /path/to/repo1          # explicit board repos
scan:
  - /path/to/parent-dir     # auto-discover direct subdirs that have a .karr
```

Each repo carries a `.karr` file describing how to run its agent:

```yaml
claude: true                # synthesize the canonical claude command (opt-in)
claude_bin: claude          # binary for claude: true (default: claude)
claude_max_turns: 30        # --max-turns for claude: true
claude_permission_mode: bypassPermissions
prompt: >-                  # agent instruction, exposed to the command as $PROMPT
  Use the karr-coordinator skill: pick the next actionable task and move it.
# command: claude -p "$PROMPT"   # explicit command; wins over claude: true
on_idle: skip               # 'skip' (default) | 'always-run'
max_runtime: 1800           # per-command SIGKILL in seconds (0 = no timeout)
drain: true                 # loop until drained (default) | false: single run
max_attempts: 2             # stalls on one task before auto-block
max_iterations: 50          # hard cap on drain iterations (the drain budget)
cooldown_base: 1            # cooldown minutes at level 0
cooldown_max: 64            # cooldown ceiling in minutes
error_patterns:             # extra case-insensitive substrings → common-error
  - my custom api error
```

`claude`, `claude_bin`, the `claude_*` knobs, `command` and `prompt` may also be
set globally in `config.yml` (as `default_command` / `default_prompt`); the
per-repo `.karr` value wins. The agent's output streams to the terminal when run
interactively or with `--verbose`, and is always appended to `.karr.log`.

A board can also opt out **in its own karr state**, which is what a global
`default_command` otherwise makes impossible:

```bash
karr disable --reason "abandoned driver, backlog parked"
karr enable
```

Unlike `.karr` — local machine state — the flag is board state
(`foundation.enabled` in `refs/karr/config`), so it syncs with the board and
every foundation instance on every machine honours it. A disabled board is
skipped **whole**: the flag is checked before the agent command is resolved and
before the drain decision, so there is no drain, no auto-block and no agent run.
It wins over `--command`, `default_command`, the `.karr` `command` and
`claude: true`, and `--force` does *not* override it. `--status` shows such a
board with a `disabled` flag and its reason. The same state is visible and
settable through `karr config` (`foundation.enabled` / `foundation.reason`).

After every agent run, foundation classifies the outcome from what it can
observe — exit code, board ref movement, and the run's captured output:

- **progress** — the board changed; keep draining.
- **stall** — a task the agent claimed or left `in-progress` did not move. Its
  attempt counter is bumped, and at `max_attempts` it is **auto-blocked** (a
  `blocked:` reason is written so it drops out of the actionable set and the
  drain can finish). The agent may always set a better reason itself with
  `karr edit --block`; the auto-block is only a fallback so the loop always
  terminates.
- **common-error** — a non-zero/timeout exit, or output matching a known
  pattern (rate limit, auth, network, 5xx, plus your `error_patterns`). No task
  is penalized; the repo enters an **exponential cooldown** (`cooldown_base` ×
  2^level minutes, capped at `cooldown_max`, reset on the next clean run) and is
  skipped until it expires.
- **idle** — the agent did nothing and grabbed nothing; stop.

Concurrent invocations are safe: a PID lock per repo means a cron tick that
fires while an agent is still running simply skips that repo. All per-repo state
is gitignored: `.karr.state` (board hash, per-task attempts, cooldown, last
error), `.karr.lock`, and `.karr.log`.

## Helper refs

Not all shared workflow state belongs in tasks. `karr` also supports arbitrary
non-protected refs outside `refs/karr/*`.

```bash
karr set-refs superpowers/spec/1234.md draft ready
karr get-refs superpowers/spec/1234.md
```

Use this for:

- planning blobs
- generated specs
- agent scratch state
- workflow metadata you want synced through Git but not modeled as cards

Protected namespaces such as branches, tags, remotes, stash, `refs/karr/*` and
`refs/karr-local/*` (where `karr pick` keeps its process-local locks) are
blocked.

## Skills

The distribution ships a bundled `karr` skill that can be installed locally in
a repo or globally in the current home directory.

```bash
karr skill install
karr skill install --agent claude-code
karr skill install --agent codex --global --force
karr skill check --global
karr skill update
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
id: 1
title: Fix login bug
status: in-progress
priority: high
class: standard
claimed_by: agent-fox
created: 2026-03-12T10:00:00Z
updated: 2026-03-12T10:00:00Z
---

Task description here.
```

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

This is free software; you can redistribute it and/or modify it under the same
terms as the Perl 5 programming language system itself.
