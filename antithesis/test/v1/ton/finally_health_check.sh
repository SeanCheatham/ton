#!/usr/bin/env bash
set -euo pipefail

# Final health check: verify the validator process is still running.
# This is a minimal placeholder for the antithesis-workload skill to expand.

VALIDATOR_HOST="${VALIDATOR_HOST:-validator}"

echo "Running final health check..."
if nc -z -u "${VALIDATOR_HOST}" 30001 2>/dev/null; then
    echo "PASS: validator is reachable"
    exit 0
else
    echo "FAIL: validator is not reachable"
    exit 1
fi
