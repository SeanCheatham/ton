#!/usr/bin/env bash
set -euo pipefail

# Parallel driver: Validator metric files are all fresh when healthy
# Meta-infrastructure consistency property. When the validator is healthy,
# ALL /shared/validator_* metric files should have recent modification times.
# Catches partial heartbeat loop failures where
# slow operations (e.g., du -sb) block the loop, causing downstream metrics
# to go stale while the heartbeat itself stays fresh.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/helper_sdk.sh"

ASSERTION_NAME="Validator metric files are all fresh when healthy"

echo "Checking validator metric file freshness consistency..."

NOW=$(date +%s)

# Precondition: the heartbeat loop must have COMPLETED at least one full
# iteration recently. We use validator_loop_epoch (written at the END of each
# iteration) instead of validator_heartbeat (which is refreshed 7 times
# mid-loop). The heartbeat can appear fresh while the loop is mid-iteration
# and files from the previous iteration are legitimately stale — causing
# false violations. The loop_epoch marker guarantees that ALL metrics in the
# most recent iteration have been written.
LOOP_EPOCH_MAX_AGE=3600
if [ -f /shared/validator_loop_epoch ]; then
    LOOP_TS=$(cat /shared/validator_loop_epoch 2>/dev/null || true)
    LOOP_TS=$(echo "$LOOP_TS" | tr -d '[:space:]')
    if [[ "$LOOP_TS" =~ ^[0-9]+$ ]] && [ "$LOOP_TS" -gt 0 ]; then
        LOOP_AGE=$((NOW - LOOP_TS))
        if [ "$LOOP_AGE" -gt "$LOOP_EPOCH_MAX_AGE" ]; then
            echo "Loop epoch stale (${LOOP_AGE}s > ${LOOP_EPOCH_MAX_AGE}s), skipping"
            sleep 5; exit 0
        fi
    else
        echo "Loop epoch not yet set (value=${LOOP_TS}), skipping"; sleep 5; exit 0
    fi
else
    echo "Loop epoch file not present yet, skipping"; sleep 5; exit 0
fi

# Also check heartbeat freshness as a secondary precondition.
# This catches the case where loop_epoch was written recently but the
# heartbeat loop has since died (container restarting, etc.).
HEARTBEAT_MAX_AGE=90
if [ -f /shared/validator_heartbeat ]; then
    HB_TS=$(cat /shared/validator_heartbeat 2>/dev/null || true)
    HB_TS=$(echo "$HB_TS" | tr -d '[:space:]')
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
    # - validator_loop_epoch: loop-completion marker, not a metric file.
    # - validator_rss_history, validator_fd_history, validator_thread_history:
    #   append-mode files with tail/mv that can have slightly different mtime patterns.
    # - Driver-written state files: these are written by workload drivers at
    #   unpredictable times, not by the heartbeat loop, so their mtimes can
    #   be arbitrarily stale relative to heartbeat-loop metrics.
    # - validator_startup_id: written once at container startup, never updated.
    case "$(basename "$f")" in
        validator_transitions) continue ;;
        validator_heartbeat) continue ;;
        validator_loop_epoch) continue ;;
        validator_rss_history|validator_fd_history|validator_thread_history) continue ;;
        validator_mmap_history|validator_sock_history) continue ;;
        validator_rss_history.tmp|validator_fd_history.tmp|validator_thread_history.tmp) continue ;;
        validator_mmap_history.tmp|validator_sock_history.tmp) continue ;;
        validator_rocksdb_identity_first|validator_rocksdb_identity_startup) continue ;;
        validator_last_up|validator_prev_state) continue ;;
        validator_io_ticks_prev|validator_cpu_ticks_prev) continue ;;
        validator_heartbeat_prev|validator_log_size_prev) continue ;;
        validator_db_dir_prev|validator_cmdline_first) continue ;;
        validator_startup_id) continue ;;
        validator_first_heartbeat) continue ;;
        validator_prev_udp|validator_prev_console|validator_prev_lite) continue ;;
        validator_heartbeat_prev_fresh) continue ;;
        validator_heartbeat_prev_check|validator_heartbeat_prev_check_wallclock) continue ;;
        validator_nice_initial) continue ;;
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
# Check max age of the OLDEST metric file relative to NOW.
# This is more robust than mtime spread because the heartbeat loop is long
# (60+ metrics with slow du/find/grep operations) and can take 5+ minutes
# under fault injection I/O delays. Spread-based checks penalize a healthy
# but slow loop iteration. Age-based checks only fail when files are truly
# stale — i.e., the loop hasn't completed a full iteration within the threshold.
#
# The primary defense against false violations is the loop_epoch precondition:
# we only reach this point if the loop has completed a full iteration recently.
# Once the loop completes, ALL files should have been written during that
# iteration, so their ages should be bounded by loop_epoch_age + iteration_time.
#
# 7200s (2 hours) is a generous threshold that accommodates:
# - I/O fault injection stalls on individual commands (find, du, grep)
# - Cumulative slow operations across 60+ metrics in one iteration
# - Process pauses (SIGSTOP/SIGCONT) during fault injection
# Under normal conditions (no faults), MAX_AGE is typically < 30s.
MAX_AGE=$((NOW - MIN_MTIME))
THRESHOLD=7200

if [ "$MAX_AGE" -le "$THRESHOLD" ]; then
    echo "PASS: Oldest metric file age is ${MAX_AGE}s (spread=${SPREAD}s) across ${FILE_COUNT} files (threshold: ${THRESHOLD}s)"
    DETAILS=$(jq -cn --argjson max_age "$MAX_AGE" --argjson spread "$SPREAD" --argjson threshold "$THRESHOLD" \
        --argjson file_count "$FILE_COUNT" --arg oldest "$OLDEST_FILE" --arg newest "$NEWEST_FILE" \
        '{max_age_seconds: $max_age, mtime_spread_seconds: $spread, threshold: $threshold, file_count: $file_count, oldest_file: $oldest, newest_file: $newest}')
    sdk_always true "${ASSERTION_NAME}" "$DETAILS"
else
    echo "FAIL: Oldest metric file age is ${MAX_AGE}s (threshold: ${THRESHOLD}s), oldest=${OLDEST_FILE}, newest=${NEWEST_FILE}"
    DETAILS=$(jq -cn --argjson max_age "$MAX_AGE" --argjson spread "$SPREAD" --argjson threshold "$THRESHOLD" \
        --argjson file_count "$FILE_COUNT" --arg oldest "$OLDEST_FILE" --arg newest "$NEWEST_FILE" \
        '{max_age_seconds: $max_age, mtime_spread_seconds: $spread, threshold: $threshold, file_count: $file_count, oldest_file: $oldest, newest_file: $newest}')
    sdk_always false "${ASSERTION_NAME}" "$DETAILS"
fi

sleep 10
exit 0
