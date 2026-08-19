#!/usr/bin/env bash
# Demo agent for the ex/ fleet sandbox.
#
# Works the card named by $KARR_TASK (ticket mode) or picks the next assignable
# card itself (drain mode): reads it, moves it to review under a fresh claim
# and hands it off. That makes the board move, so karr-foundation classifies
# the run as progress.
set -euo pipefail

EX="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "$EX/.." && pwd)"

karr() {
  if [ -n "${KARR_BIN:-}" ]; then "$KARR_BIN" "$@"
  else perl -I"$REPO_ROOT/lib" "$REPO_ROOT/bin/karr" "$@"; fi
}

cd "$KARR_REPO"
NAME="$(karr agentname)"

if [ -n "${KARR_TASK:-}" ]; then
  ID="$KARR_TASK"
else
  # drain mode: claim the next assignable card ourselves.
  PICK="$(karr pick --claim "$NAME" --json)"
  ID="$(printf '%s' "$PICK" | sed -n 's/.*"id": *\([0-9][0-9]*\).*/\1/p')"
  if [ -z "$ID" ]; then
    echo "fake-agent: nothing to pick"
    exit 0
  fi
fi

echo "fake-agent: working on #$ID"
karr show "$ID" >/dev/null
karr move "$ID" review --claim "$NAME"
karr handoff "$ID" --claim "$NAME" --note "handled by the demo agent" --timestamp --release
echo "fake-agent: #$ID -> review, handed off"
