#!/usr/bin/env bash
set -euo pipefail

# Driver workload: verify the validator log file is being actively written.
# When the validator is healthy (heartbeat fresh and at least one port reachable),
# /shared/validator.log must have been modified within the last 60 seconds.
# Catches internal deadlocks where the process holds ports but stops all logging.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/helper_sdk.sh"

VALIDATOR_HOST="${VALIDATOR_HOST:-validator}"
UDP_PORT="${VALIDATOR_PORT:-30001}"
CONSOLE_PORT="${CONSOLE_PORT:-30002}"
LITE_PORT="${LITE_PORT:-30003}"

ASSERTION_NAME="Validator log mtime is fresh when healthy"
sdk_catalog_always "$ASSERTION_NAME"

# Check heartbeat freshness (within 30s)
NOW=$(date +%s)
if [[ -f /shared/validator_heartbeat ]]; then
    HB_TS=$(cat /shared/validator_heartbeat 2>/dev/null || echo "0")
    if [[ "$HB_TS" =~ ^[0-9]+$ ]] && [ "$HB_TS" -gt 0 ]; then
        HB_AGE=$((NOW - HB_TS))
    else
        HB_AGE=999
    fi
else
    HB_AGE=999
fi

if [ "$HB_AGE" -gt 30 ]; then
    echo "Heartbeat stale (${HB_AGE}s), skipping log freshness check"
    exit 0
fi

# Check at least one port reachable
any_port=false
nc -z -u -w 2 "${VALIDATOR_HOST}" "${UDP_PORT}" 2>/dev/null && any_port=true
if [[ "$any_port" != "true" ]]; then
    nc -z -w 2 "${VALIDATOR_HOST}" "${CONSOLE_PORT}" 2>/dev/null && any_port=true
fi
if [[ "$any_port" != "true" ]]; then
    nc -z -w 2 "${VALIDATOR_HOST}" "${LITE_PORT}" 2>/dev/null && any_port=true
fi

if [[ "$any_port" != "true" ]]; then
    echo "No ports reachable, skipping log freshness check"
    exit 0
fi

# Check log file mtime
LOG_FILE="/shared/validator.log"
if [[ ! -f "$LOG_FILE" ]]; then
    echo "Log file does not exist yet, skipping"
    exit 0
fi

LOG_MTIME=$(stat -c %Y "$LOG_FILE" 2>/dev/null || echo "0")
if [ "$LOG_MTIME" -eq 0 ]; then
    echo "Could not stat log file, skipping"
    exit 0
fi

LOG_AGE=$((NOW - LOG_MTIME))
echo "Log file age: ${LOG_AGE}s (mtime=${LOG_MTIME}, now=${NOW})"

details=$(jq -cn \
    --argjson log_age "$LOG_AGE" \
    --argjson log_mtime "$LOG_MTIME" \
    --argjson now "$NOW" \
    --argjson hb_age "$HB_AGE" \
    '{log_age_s: $log_age, log_mtime: $log_mtime, now: $now, heartbeat_age_s: $hb_age}')

if [ "$LOG_AGE" -lt 60 ]; then
    sdk_always true "$ASSERTION_NAME" "$details"
else
    echo "WARNING: Log file is ${LOG_AGE}s old while validator appears healthy"
    sdk_always false "$ASSERTION_NAME" "$details"
fi

exit 0
