# The board push is guarded

Every command that writes the board pulls, writes its refs locally and pushes.
Until 0.603 that push sent the board under the forced refspec
`+refs/karr/*:refs/karr/*`: it carried no expectation of what the remote held,
so whichever of two clones pushed second replaced the first one's refs. Two
`karr create` in the window between pull and push allocated the same id from
the same counter, and one card was gone; two `karr pick` handed one card to
two agents. Nothing was parked on either side -- the loser had already pushed,
so its next pull adopted the winner's version as an ordinary remote update
(k322).

## Decision

The board push is a compare-and-swap on what this clone last saw on the
remote, and a push that loses it is never sent again unchanged.

- **What goes out.** Only the board refs whose local value differs from the
  tracking mirror `refs/karr-remote/<remote>/*`, plus a deletion for every
  tombstone under `refs/karr-local/deleted/` whose ref the mirror has. Each
  one carries the mirror's value as its expectation; a ref the mirror does
  not have must not exist on the remote (create-only).
- **How.** Through the git CLI: `git push --porcelain --atomic
  --force-with-lease=<ref>:<expected> <oid>:<ref> ...`. The remote checks the
  expectation under its own ref lock, and `--atomic` keeps a card and the
  activity log entry about it together: both land or neither does. Where no
  git binary can be started (or `KARR_NO_CLI_FALLBACK` is set) the native
  transport checks the expectations against a fetch taken immediately before
  the push. That leaves one round trip open until Git::Native binds libgit2's
  push negotiation callback (p5-git-native k34).
- **Stale.** A push whose expectations failed reports the refs in
  `push_stale`, separate from `push_rejections`. Contention ("cannot lock
  ref", "a reference with that name already exists") is retried as before;
  the retry carries the same expectations, so if the other push landed it
  comes back stale rather than overwriting it.
- **After a stale push.** Each process records the board refs it wrote since
  its pull (`start_journal`). If none of the stale refs is one of those --
  older local work, the id counter -- the other clone's versions are pulled
  in (a conflict is parked and reported, as on every pull) and the push goes
  again, up to three rounds. If the command's own writes went stale, they are
  taken back (`take_back_journal`: each ref is compare-and-swapped back to its
  value before the command, the id counter excepted, which only moves
  forward) and the remote's version is pulled in. `create` and `pick` then run
  again from the top -- the card takes the next free id, the pick moves on to
  the next candidate. Every other command stops with exit 1, names the card
  that changed and says that nothing of it was published.
- **Republishing** a board over a remote that is empty or presents a
  different board is `karr sync --push --force`, the old forced push, and
  nothing else uses it. The wholesale-wipe and foreign-board refusals name it.

## Considered and rejected

- **Re-apply every command after a stale push.** `move`, `edit`, `handoff`,
  `archive` and `delete` print per card before their push, may have asked for
  confirmation, and change a card the caller named. Re-running them on top of
  another clone's change, unseen, is the silent merge this decision exists to
  prevent. `create` and `pick` decide afresh from the board; the others would
  only repeat a decision made against a board that no longer exists.
- **Park the losing version and keep going.** That is what a pull already
  does with a genuine conflict, and it is right there: both sides published.
  The loser of a push race published nothing; parking its card under
  `refs/karr-conflict/` would report a conflict that is really a lost create.
- **Native compare-and-swap only.** libgit2 offers no push-time expectation
  without push negotiation, which Git::Native does not bind yet.

## What this accepts

- The board push spawns `git` where it used to stay in-process; the native
  route remains for machines without a git binary, with its one-round-trip
  window.
- A plain `karr sync --push` after the remote was wiped sends nothing and
  exits 0: the mirror still says the remote holds the board. The next writing
  command's wipe guard says what to run.
- A command re-run after a stale push reads the board config once per
  process; a config change published in the same window is picked up by the
  next command, not the re-run.
