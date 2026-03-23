#!/usr/bin/env bash
set -euo pipefail

# Parallel driver: Validator metric files are all fresh when healthy
# Meta-infrastructure consistency property. When the validator is healthy,
# ALL /shared/validator_* metric files should have modification times within
# 60 seconds of each other. Catches partial heartbeat loop failures where
# slow operations (e.g., du -sb) block the loop, causing downstream metrics
# to go stale while the heartbeat itself stays fresh.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/helper_sdk.sh"

ASSERTION_NAME="Validator metric files are all fresh when healthy"

echo "Checking validator metric file freshness consistency..."

# Heartbeat-only precondition: heartbeat freshness proves the validator process
# is actively running and metrics are valid, regardless of port status.
HEARTBEAT_MAX_AGE=90
if [ -f /shared/validator_heartbeat ]; then
    HB_TS=$(cat /shared/validator_heartbeat 2>/dev/null | tr -d '[:space:]')
    NOW=$(date +%s)
    if [[ "$HB_TS" =~ ^[0-9]+$ ]]; then
        AGE=$((NOW - HB_TS))
        if [ "$AGE" -gt "$HEARTBEAT_MAX_AGE" ]; then
            echo "Heartbeat stale (${AGE}s > ${HEARTBEAT_MAX_AGE}s), skipping"
            sleep 5; exit 0
        fi
    else
        echo "Heartbeat value invalid, skipping"; sleep 5; exit 0
    fi
else
    echo "Heartbeat file not present yet, skipping"; sleep 5; exit 0
fi

# Collect mtimes of all validator_* metric files
MIN_MTIME=999999999999
MAX_MTIME=0
FILE_COUNT=0
OLDEST_FILE=""
NEWEST_FILE=""

for f in /shared/validator_*; do
    [ -f "$f" ] || continue
    # Skip files that are not regular metrics written once per loop iteration:
    # - validator_transitions: written by workload drivers, not the heartbeat loop
    # - validator_heartbeat: written multiple times per loop iteration (7 times)
    #   to keep it fresh for heartbeat-based preconditions in other drivers.
    #   Including it would always make it the newest file, inflating the spread
    #   to equal the full loop duration rather than measuring metric staleness.
    # - validator_rss_history, validator_fd_history, validator_thread_history:
    #   append-mode files with tail/mv that can have slightly different mtime patterns.
    # - Driver-written state files: these are written by workload drivers at
    #   unpredictable times, not by the heartbeat loop, so their mtimes can
    #   be arbitrarily stale relative to heartbeat-loop metrics.
    # - validator_startup_id: written once at container startup, never updated.
    case "$(basename "$f")" in
        validator_transitions) continue ;;
        validator_heartbeat) continue ;;
        validator_rss_history|validator_fd_history|validator_thread_history) continue ;;
        validator_rss_history.tmp|validator_fd_history.tmp|validator_thread_history.tmp) continue ;;
        validator_rocksdb_identity_first|validator_rocksdb_identity_startup) continue ;;
        validator_last_up|validator_prev_state) continue ;;
        validator_io_ticks_prev|validator_cpu_ticks_prev) continue ;;
        validator_heartbeat_prev|validator_log_size_prev) continue ;;
        validator_db_dir_prev|validator_cmdline_first) continue ;;
        validator_startup_id) continue ;;
    esac
    MTIME=$(stat -c %Y "$f" 2>/dev/null || continue)
    FILE_COUNT=$((FILE_COUNT + 1))
    if [ "$MTIME" -lt "$MIN_MTIME" ]; then
        MIN_MTIME=$MTIME
        OLDEST_FILE=$(basename "$f")
    fi
    if [ "$MTIME" -gt "$MAX_MTIME" ]; then
        MAX_MTIME=$MTIME
        NEWEST_FILE=$(basename "$f")
    fi
done

if [ "$FILE_COUNT" -lt 2 ]; then
    echo "SKIP: fewer than 2 metric files found (${FILE_COUNT})"
    sleep 10
    exit 0
fi

SPREAD=$((MAX_MTIME - MIN_MTIME))
# Threshold must accommodate the full heartbeat loop duration.
# The loop includes multiple slow operations (du -sb, find, jq, grep)
# that can each take 10-30s under fault injection I/O delays.
# Under heavy fault injection, the full loop can take 3-5 minutes due to
# I/O stalls on filesystem operations (du, find, stat, jq). 300s is generous
# enough to avoid false positives while still detecting truly stuck loops.
THRESHOLD=300

if [ "$SPREAD" -le "$THRESHOLD" ]; then
    echo "PASS: Metric file mtime spread is ${SPREAD}s across ${FILE_COUNT} files (threshold: ${THRESHOLD}s)"
    DETAILS=$(jq -cn --argjson spread "$SPREAD" --argjson threshold "$THRESHOLD" \
        --argjson file_count "$FILE_COUNT" --arg oldest "$OLDEST_FILE" --arg newest "$NEWEST_FILE" \
        '{mtime_spread_seconds: $spread, threshold: $threshold, file_count: $file_count, oldest_file: $oldest, newest_file: $newest}')
    sdk_always true "${ASSERTION_NAME}" "$DETAILS"
else
    echo "FAIL: Metric file mtime spread is ${SPREAD}s (threshold: ${THRESHOLD}s), oldest=${OLDEST_FILE}, newest=${NEWEST_FILE}"
    DETAILS=$(jq -cn --argjson spread "$SPREAD" --argjson threshold "$THRESHOLD" \
        --argjson file_count "$FILE_COUNT" --arg oldest "$OLDEST_FILE" --arg newest "$NEWEST_FILE" \
        '{mtime_spread_seconds: $spread, threshold: $threshold, file_count: $file_count, oldest_file: $oldest, newest_file: $newest}')
    sdk_always false "${ASSERTION_NAME}" "$DETAILS"
fi

sleep 10
exit 0
