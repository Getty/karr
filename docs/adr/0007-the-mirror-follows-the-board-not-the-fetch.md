# The tracking mirror follows the board, not the fetch

A pull decides, per ref, between four cases, and what tells them apart is the
tracking mirror `refs/karr-remote/<remote>/*`: the remote state this clone
last reconciled its board against. "The local ref differs from the mirror and
the remote does not" means unpushed local work, which is kept and then pushed.

Until 0.602 the fetch wrote the remote's refs straight into that mirror, and
the reconciliation afterwards brought the board in line with it. Between those
two steps the mirror made a claim that was not true yet. A pull that stopped
there never made it true: a transport that reported a failure after its refs
had landed (a CLI fallback killed at the timeout does exactly that), a process
killed before or during the reconciliation. The next pull then read every stale
local ref as unpushed work and the push wrote it over the remote's newer card,
in every clone, at exit 0. In a fresh clone the same state made the whole
board read as deleted locally (k324). The earlier fix for a ref that could not
be applied (k154) put the mirror back by hand for that one failure and for the
two refusals, which left every exit it did not know about open.

## Decision

The fetch gets a namespace of its own, and the mirror is written in one place.

- `pull` fetches `refs/karr/*` into `refs/karr-local/fetched/<remote>/*`
  (`FETCH_ROOT`); `pull_foundation` fetches into
  `refs/karr-local/foundation-fetched/<remote>/*`. These hold the remote as
  the last fetch found it and nothing else. Nothing reads them except the pull
  whose fetch just succeeded.
- The reconciliation computes its plan from three points: the board (L), the
  mirror (T) and the fetched copy (R).
- A mirror entry moves only in `_advance_mirror_ref`, and only after the board
  holds what the entry is about to say: the remote's version was adopted, or
  board and remote were found to agree. (And after a push, as before, for the
  refs that push carried.)

A pull that stops anywhere therefore leaves the mirror entries of the refs it
did not finish where they were, and the next pull decides those refs again.
There is nothing to roll back, so `_restore_mirror`, `_rollback_mirror_ref`
and the "tracking mirror could not be put back" note are gone, and the
wholesale-wipe and foreign-board refusals repeat on the next pull by
construction rather than by a restore that could itself fail.

## Considered and rejected

- **Restore the mirror when the fetch fails.** Closes the transport door and
  not the killed-process one; a kill runs no cleanup.
- **A journal ref written before the fetch, replayed by the next pull.**
  Closes both, but has to tell an interrupted pull from one still running in
  another process of the same clone, which several agents in one checkout
  make the normal case. That needs a liveness test (pid, host, age) whose
  every wrong answer is the original bug again.

## What this accepts

- One more copy of the remote's ref names per clone. The first pull of a
  fresh clone writes each board ref three times (fetched, board, mirror)
  instead of twice.
- A mirror write that fails after the board took the ref is not reported. The
  entry stays behind the board, the next pull finds board and remote in
  agreement and writes it then.
- A clone that an older karr left with its mirror ahead of its board cannot be
  recognised: the mirror carries no record of what it held before. Such a
  clone is repaired by hand, by deleting `refs/karr-remote/` before the next
  `karr sync`; nothing is pushed by that.
- Both namespaces sit under `refs/karr-local/`, which no refspec carries and
  `karr set-refs` cannot reach, so they need no protection of their own.
