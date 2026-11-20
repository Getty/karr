# A clone that cannot write the board is read-only

The ADR directory holds two files each numbered 0001 and 0002; 0008 is the
highest number in use, so this one takes the next free number, 0009.

Until 0.603 a board write whose push failed stayed in the clone: the command
printed "Local refs are intact", exited 1, and the card lived in that one
clone. Where the push fails because the remote denies writing -- a public
repository cloned over `https://` without credentials, a read-only deploy key
-- no retry can ever publish it. The card then sits in one clone for hours, no
other clone sees it, and another clone can hand out the same card number. Every
later `karr list` there was silent (k333).

## Decision

A board change that cannot reach the remote because the remote denies writing
must not stay in the clone. The clone becomes read-only for the board instead,
and every later write is refused before anything is written.

- **The state.** Two modes, `denied` (learned from a push the remote denied
  write access) and `on` (set or confirmed by hand). It carries the push URL it
  applies to, and for `denied` the short reason and the time (UTC). The same
  place keeps the cause and time of the last push that failed for another reason
  (unreachable, rejected, stale, other), for the warning about changes that are
  not on the remote.
- **Where it is stored.** In the clone's git config (`karr.readonly`,
  `karr.readonlyPushUrl`, `karr.readonlyReason`, `karr.readonlySince`, and
  `karr.lastPushFailure` / `lastPushReason` / `lastPushAt`), never on the
  board. The board config is every clone's at once: "this clone cannot write"
  written there would be pushed to the clones that can, or could not be pushed
  at all from the one that cannot. Whether a clone may write is a property of
  that clone and its credentials, so it lives with that clone's git
  configuration. The push URL is stored without userinfo.
- **Learning.** The first push that fails with class `denied`
  (`App::karr::Git::push_failure`) takes this command's own writes back -- the
  card, next-id and log entries included, with the mechanism the stale push
  uses (ADR 0008) -- records `denied`, and exits 1 with the denial message.
  Unreachable keeps its three attempts and the change stays in the clone; only a
  denial changes the clone's mode.
- **Refusing before writing.** In `denied` or `on`, every command that writes
  board refs is refused after its pull and before its first ref write, exit 1.
  No push is attempted, so the cost beyond the pull is nil. `--local-only` is
  refused too: in a read-only clone a local-only change could never be
  published. Reading and pulling keep working in every state.
- **How it lifts.** Three ways. (1) The remote's effective push URL (`pushurl`,
  else `url`) no longer equals the recorded one: the state stops applying, and
  the stale keys are dropped after the next push that lands. (2) `karr sync`
  pulls and tries the push in `denied`; a push that lands -- or its dry-run
  probe succeeding -- clears the state, which covers a credential added without
  the URL changing. A denied push leaves it as it is. (3) `karr readonly off`
  clears it by hand; the next write tries again and learns `denied` again if
  writing is still not allowed.
- **`karr readonly on`** is for a clone that is only for reading, say a
  checkout for browsing the board: it is refused to write from the start, and
  `karr sync` only pulls. It is the call of the clone's maintainer; an agent
  does not run it on its own initiative, because it turns a missing access into
  a decision that nobody took.
- **karr-foundation** treats a read-only board like a disabled one (it is not
  run), marks it `read-only: denied` / `read-only: on` in its overview, and a
  read-only hub refuses ask, answer, plan and chain.

## Why not guess from the URL

An `https://` URL looks like a clone that cannot write, and often is -- but a
clone that fetches over `https://` and pushes over an SSH `pushurl` writes
fine, and so does one whose HTTPS URL carries a credential helper. Guessing
read-only from the URL would refuse writes that would have worked. The state is
learned from the one thing that knows: a push the remote denied. The URL only
decides when the learned state stops applying.

## Why the change is taken back, not kept

Keeping it is what 0.603 did. A change that is in one clone and can never leave
it is worse than no change: it looks done, it is invisible to everyone else, and
it reserves a card number the board does not know about. Taking it back leaves
the clone exactly as it was, so the message can say the one true thing -- nothing
was changed -- and the agent can run the command again once the access is fixed.
This is the opposite of an unreachable remote, where the push may succeed a
minute later: that change stays, is reported as "saved in this clone, not on the
remote", and `karr sync` publishes it.

## What this accepts

- The first write in a clone that cannot write costs a pull and a failed push,
  and is taken back. Only that one pays; the rest are refused after the pull.
- The state is per clone and per push URL: a second clone of the same
  repository learns it again, and a clone moved to another URL forgets it.
- A credential added without a URL change is not noticed until `karr sync` or
  `karr readonly off`; the lasting warning on every command is the cue.
