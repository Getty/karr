#!/usr/bin/env bash
# Demo agent that fails like a rate-limited one — lets karr-foundation show
# the common-error path and the exponential cooldown.
set -euo pipefail
echo "API error: 429 Too Many Requests"
exit 1
