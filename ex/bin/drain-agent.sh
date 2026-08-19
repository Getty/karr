#!/usr/bin/env bash
# Drain agent for the ex/ sandbox: picks the next assignable card itself and
# works it all the way to done. A karr-foundation drain run terminates only
# when no actionable cards are left, so this agent finishes cards instead of
# parking them in review like the ticket-mode fake-agent does.
set -euo pipefail

EX="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "$EX/.." && pwd)"

karr() {
  if [ -n "${KARR_BIN:-}" ]; then "$KARR_BIN" "$@"
  else perl -I"$REPO_ROOT/lib" "$REPO_ROOT/bin/karr" "$@"; fi
}

cd "$KARR_REPO"
NAME="$(karr agentname)"

PICK="$(karr pick --claim "$NAME" --json)"
ID="$(printf '%s' "$PICK" | sed -n 's/.*"id": *\([0-9][0-9]*\).*/\1/p')"
if [ -z "$ID" ]; then
  echo "drain-agent: nothing to pick"
  exit 0
fi

echo "drain-agent: working on #$ID"
karr show "$ID" >/dev/null
karr move "$ID" done --claim "$NAME"
karr edit "$ID" --release
echo "drain-agent: #$ID -> done"
