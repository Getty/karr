# App::karr House Rules

The shared house rules come from skilletor — bundle `getty-cpan-dist@getty`: engineering
discipline, the delegation lock, the publish gate, karr coordination, CPAN release. They load
as `.claude/rules/.local.*.md`; if they are missing, run `skilletor sync` and publish nothing
until they load. This file adds what is true only here, and wins where it differs.

## What this repo is

App::karr — Kanban Assignment & Responsibility Registry, the tool behind the board itself.
Read first: exports, immediate callers and the shared utilities (`Role/*`, `BoardStore`,
`Git`, `Task`, `Config`).

## Agent team

| Task | Agent |
|---|---|
| Task/config semantics, lifecycle, claims, dependencies, activity log, ordinary board commands, filtering, rendering, `context`, `metrics` | `karr-board-worker` |
| Git transport, refs-backed persistence, CAS, locks, sync, encoding, `init`/`sync`/`materialize`/`import`/`repair`/`backup`/`restore`/`destroy`/`unlock`, share-file plumbing | `karr-ref-worker` |
| karr-foundation: multi-board discovery, overview, agent command resolution, drain loops, `.karr.lock`/`.karr.state`, cooldown, stall detection, auto-blocking, `disable`/`enable` | `karr-foundation-worker` |
| Behavior-relevant code that spans those domains, or none of them cleanly | `karr-worker` (generalist fallback) |
| Write/extend tests under `t/` | `karr-test-writer` |
| Commits, `Changes`, card → done, pre-release audit | `karr-release-manager` |
| Docs: POD, README, `CONTEXT.md`, ADRs, shipped skills; doc audits | `karr-doc-writer` |
| Read-only research, audit, gap analysis | the narrowest domain worker ("read-only, change nothing") |

Pick the narrowest domain worker that covers the task — they brief on one domain instead of the
whole distribution, and each one names the other two in its own boundaries section, so a task
that turns out to belong elsewhere gets handed back rather than solved from the wrong context.
`karr-worker` stays for work that genuinely crosses the seams.

Behavior-relevant = CLI command logic (`Cmd/*`), refs-backed storage (`BoardStore`, `Git`,
`Lock`, `SyncGuard`), `Task`/`Config` parsing and writing, sync lifecycle, tests.

## Coordination — dogfood

This repo manages its own work on its own board — `refs/karr/*` already exists here; karr is
the tool *and* the workflow. Bugs found while dogfooding become tickets on this board.

`export KARR_CLAIM=$(karr agent-name)` — name yourself **once** per session; `pick`, `handoff`
and `list --claimed-by` then default to it, so the handoff matches the claim. `create`, `move`
and `edit` take it only when the card ends up in a `require_claim` column (`in-progress`,
`review`): a card you file, promote to `todo` or annotate stays unclaimed, so others can pick
it. Full command surface (pick / context / set-refs / multi-agent): skill
`kanban-issues-karr-coordination`.

## Release

After a release the `$VERSION` bump is a separate, deliberate commit, and it touches every file
under `lib/` and `bin/` — each one carries its own `our $VERSION`, not just `lib/App/karr.pm`.

## Perl specifics — reference, don't restate

Module loading, Moo/Moose patterns, cpanfile pinning for Getty-authored deps, and house style
live in skill `getty-perl-core` (force-loaded for `karr-*` agents).
