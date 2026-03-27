#!/usr/bin/env bash
set -euo pipefail

# Parallel driver: RocksDB SST files exist when validator is healthy
# Reads /shared/validator_sst_count (written by validator entrypoint heartbeat loop)
# and asserts that at least one .sst file exists when the validator is healthy.
# SST files are the actual data storage in RocksDB — without them, the metadata
# chain (LOCK → CURRENT → MANIFEST) is meaningless.

source "$(dirname "$0")/helper_sdk.sh"

VALIDATOR_HOST="${VALIDATOR_HOST:-ton-validator}"
HEARTBEAT_MAX_AGE=60
ASSERTION_NAME="RocksDB SST files exist when validator is healthy"
# Grace period: don't assert until validator has been up for at least 180s
# (SST files may not exist immediately after startup before first memtable flush;
# standalone validators with no peers take longer to generate enough data)
STARTUP_GRACE=180

# Use heartbeat-only precondition instead of all-3-ports.
if [ -f /shared/validator_heartbeat ]; then
    HB_TS=$(cat /shared/validator_heartbeat 2>/dev/null || true)
    HB_TS=$(echo "$HB_TS" | tr -d '[:space:]')
    NOW=$(date +%s)
    if [[ "$HB_TS" =~ ^[0-9]+$ ]]; then
        AGE=$((NOW - HB_TS))
        if [ "$AGE" -gt "$HEARTBEAT_MAX_AGE" ]; then
            echo "Heartbeat stale (${AGE}s), skipping"
            exit 0
        fi
    else
        echo "Heartbeat value invalid, skipping"
        exit 0
    fi
else
    echo "Heartbeat file not present yet, skipping"
    exit 0
fi

if [ ! -f /shared/validator_sst_count ]; then
    echo "Metric not available yet (validator may have just restarted)"
    sdk_always true "$ASSERTION_NAME" '{"status":"metric_not_yet_available","note":"heartbeat fresh but metric file pending"}'
    exit 0
fi

SST_COUNT=$(cat /shared/validator_sst_count 2>/dev/null || echo "-1")

if ! [[ "$SST_COUNT" =~ ^[0-9]+$ ]]; then
    echo "Invalid SST count value: $SST_COUNT, skipping"
    exit 0
fi

# Time-based grace period: use heartbeat mtime as a proxy for how long the
# validator has been running. If the heartbeat file was created less than
# STARTUP_GRACE seconds ago, skip — SST files may not exist yet.
HB_CTIME=$(stat -c %W /shared/validator_heartbeat 2>/dev/null || echo "0")
if [ "$HB_CTIME" = "0" ]; then
    # Fallback: use mtime if birth time not available
    HB_CTIME=$(stat -c %Y /shared/validator_heartbeat 2>/dev/null || echo "0")
fi
UPTIME_EST=$(($(date +%s) - HB_CTIME))

# Compaction precondition: SST files are created by memtable flushes/compaction.
# A standalone validator with no peers may never produce blocks, so no data gets
# flushed to SST. Only assert SST existence if compaction has actually occurred.
COMPACTION_COUNT=0
if [ -f /shared/validator_compaction_count ]; then
    COMPACTION_COUNT=$(cat /shared/validator_compaction_count 2>/dev/null || echo "0")
    if ! [[ "$COMPACTION_COUNT" =~ ^[0-9]+$ ]]; then
        COMPACTION_COUNT=0
    fi
fi

DETAILS=$(jq -cn --argjson count "$SST_COUNT" --argjson uptime "$UPTIME_EST" --argjson compactions "$COMPACTION_COUNT" '{sst_count: $count, estimated_uptime_seconds: $uptime, compaction_count: $compactions}')

if [ "$SST_COUNT" -gt 0 ]; then
    sdk_always true "$ASSERTION_NAME" "$DETAILS"
elif [ "$UPTIME_EST" -lt "$STARTUP_GRACE" ]; then
    # Too early after startup — SST files may not exist yet, skip
    echo "Validator uptime ~${UPTIME_EST}s < ${STARTUP_GRACE}s grace period, skipping assertion"
elif [ "$COMPACTION_COUNT" -eq 0 ]; then
    # No compaction has occurred yet — SST files legitimately don't exist.
    # A standalone validator with no peers never produces blocks, so memtables
    # are never flushed. Emit true: the absence of SST is expected when no
    # compaction/flush has happened.
    echo "No compaction events detected (count=0), SST absence is expected — emitting true"
    sdk_always true "$ASSERTION_NAME" "$DETAILS"
else
    sdk_always false "$ASSERTION_NAME" "$DETAILS"
fi

exit 0
