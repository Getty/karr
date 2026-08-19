#!/usr/bin/env bash
# Demo agent that does nothing with its card and exits cleanly — lets
# karr-foundation show the stall path (and, after max_attempts, the autoblock).
set -euo pipefail
echo "lazy-agent: I cannot make progress on #${KARR_TASK:-?}"
exit 0
