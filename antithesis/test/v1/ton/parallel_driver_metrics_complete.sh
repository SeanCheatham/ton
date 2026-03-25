#!/usr/bin/env bash
set -euo pipefail

# Parallel driver: All expected validator metric files exist when healthy
# Meta-property that monitors the test infrastructure itself. When the validator
# is fully healthy (all 3 ports up, heartbeat fresh), ALL expected /shared/validator_*
# metric files must exist. If the heartbeat loop in the validator entrypoint dies,
# ALL metric files go stale and ALL dependent parallel drivers silently skip —
# making Antithesis blind. This catches that catastrophic silent failure.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/helper_sdk.sh"

ASSERTION_NAME="All expected validator metric files exist when healthy"

echo "Checking validator metric file completeness..."

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

# List of all expected metric files written by the validator heartbeat loop
EXPECTED_FILES=(
    /shared/validator_heartbeat
    /shared/validator_fd_count
    /shared/validator_mem_rss
    /shared/validator_sock_count
    /shared/validator_cpu_ticks
    /shared/validator_proc_state
    /shared/validator_io_ticks
    /shared/validator_thread_count
    /shared/validator_swap_kb
    /shared/validator_mem_peak
    /shared/validator_deleted_fds
    /shared/validator_net_bytes
    /shared/validator_net_errors
    /shared/validator_ctxt_switches
    /shared/validator_oom_score
    /shared/validator_io_bytes
    /shared/validator_unexpected_fds
    /shared/validator_db_size
    /shared/validator_db_lock
    /shared/validator_config_valid
    /shared/validator_wal_count
    /shared/validator_disk_usage
    /shared/validator_manifest_count
    /shared/validator_current_valid
    /shared/validator_global_config_valid
    /shared/validator_rocksdb_errors
    /shared/validator_sst_count
    /shared/validator_tcp_bound
    /shared/validator_db_mtime
    /shared/validator_udp_bound
    /shared/validator_current_manifest_consistent
    /shared/validator_config_keys
    /shared/validator_tcp_states
    /shared/validator_rocksdb_options
    /shared/validator_rocksdb_tmp_files
    /shared/validator_sigblk
    /shared/validator_rss_history
    /shared/validator_fd_history
    /shared/validator_db_perms
    /shared/validator_nofile_limit
    /shared/validator_log_error_count
)

TOTAL=${#EXPECTED_FILES[@]}
MISSING_COUNT=0
MISSING_NAMES=""

for f in "${EXPECTED_FILES[@]}"; do
    if [ ! -f "$f" ]; then
        MISSING_COUNT=$((MISSING_COUNT + 1))
        basename_f=$(basename "$f")
        if [ -n "$MISSING_NAMES" ]; then
            MISSING_NAMES="${MISSING_NAMES}, ${basename_f}"
        else
            MISSING_NAMES="${basename_f}"
        fi
    fi
done

if [ "$MISSING_COUNT" -eq 0 ]; then
    echo "PASS: All ${TOTAL} expected metric files exist"
    DETAILS=$(jq -cn --argjson total "$TOTAL" --argjson missing 0 \
        '{total_expected: $total, missing_count: $missing, status: "all_present"}')
    sdk_always true "${ASSERTION_NAME}" "$DETAILS"
else
    echo "FAIL: ${MISSING_COUNT} of ${TOTAL} metric files missing: ${MISSING_NAMES}"
    DETAILS=$(jq -cn --argjson total "$TOTAL" --argjson missing "$MISSING_COUNT" \
        --arg names "$MISSING_NAMES" \
        '{total_expected: $total, missing_count: $missing, missing_files: $names}')
    sdk_always false "${ASSERTION_NAME}" "$DETAILS"
fi

sleep 10
exit 0
