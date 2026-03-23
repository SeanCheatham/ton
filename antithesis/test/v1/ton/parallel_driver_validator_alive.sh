#!/usr/bin/env bash
set -euo pipefail

# Driver workload: verify the validator process is alive and its UDP port is
# reachable.  Runs repeatedly in parallel during fault injection.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/helper_sdk.sh"

VALIDATOR_HOST="${VALIDATOR_HOST:-validator}"
VALIDATOR_PORT="${VALIDATOR_PORT:-30001}"

echo "Checking validator is alive at ${VALIDATOR_HOST}:${VALIDATOR_PORT}..."

if nc -z -u "${VALIDATOR_HOST}" "${VALIDATOR_PORT}" 2>/dev/null; then
    echo "PASS: validator UDP port ${VALIDATOR_PORT} is reachable"
    sdk_sometimes true "Validator is alive during parallel driver phase"
    exit 0
else
    echo "FAIL: validator UDP port ${VALIDATOR_PORT} is not reachable"
    sdk_sometimes false "Validator is alive during parallel driver phase"
    exit 0
fi
