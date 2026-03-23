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

VALIDATOR_HOST="${VALIDATOR_HOST:-validator}"
UDP_PORT="${VALIDATOR_PORT:-30001}"
CONSOLE_PORT="${CONSOLE_PORT:-30002}"
LITE_PORT="${LITE_PORT:-30003}"

ASSERTION_NAME="All expected validator metric files exist when healthy"

echo "Checking validator metric file completeness..."

# Check all 3 ports — only assert when validator is fully healthy
udp_up=false
console_up=false
lite_up=false

nc -z -u -w 2 "${VALIDATOR_HOST}" "${UDP_PORT}" 2>/dev/null && udp_up=true
nc -z -w 1 "${VALIDATOR_HOST}" "${CONSOLE_PORT}" 2>/dev/null && console_up=true
nc -z -w 1 "${VALIDATOR_HOST}" "${LITE_PORT}" 2>/dev/null && lite_up=true

if [[ "$udp_up" != "true" || "$console_up" != "true" || "$lite_up" != "true" ]]; then
    echo "SKIP: not all ports are up (udp=${udp_up}, console=${console_up}, lite=${lite_up})"
    sleep 10
    exit 0
fi

# Check heartbeat freshness
if [ ! -f /shared/validator_heartbeat ]; then
    echo "Heartbeat file not present yet, skipping"
    sleep 10
    exit 0
fi

HB=$(cat /shared/validator_heartbeat 2>/dev/null || echo "0")
NOW=$(date +%s)
AGE=$(( NOW - HB ))
if [ "$AGE" -gt 30 ]; then
    echo "Heartbeat stale (${AGE}s old), skipping"
    sleep 10
    exit 0
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
