#!/usr/bin/env bash
set -euo pipefail

# Driver workload: check for core dump files indicating past crashes.
# When the validator heartbeat is fresh, no core dump files should exist.
# Core dumps indicate the validator (or a child process) crashed with a signal
# like SIGSEGV or SIGABRT. Even if the process recovers, the presence of a
# core file is evidence of a crash that other assertions may miss.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/helper_sdk.sh"

ASSERTION_NAME="Validator has no core dump files when healthy"
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
    echo "Heartbeat stale (${HB_AGE}s), skipping core dump check"
    exit 0
fi

# Search for core dump files
CORE_FILES=""
CORE_COUNT=0

# Search /var/ton-work with maxdepth 3
if [ -d /var/ton-work ]; then
    found=$(find /var/ton-work -maxdepth 3 -name 'core*' -type f 2>/dev/null || true)
    if [ -n "$found" ]; then
        CORE_FILES="${CORE_FILES}${found}"$'\n'
    fi
fi

# Check /tmp/core*
for f in /tmp/core*; do
    if [ -f "$f" ] 2>/dev/null; then
        CORE_FILES="${CORE_FILES}${f}"$'\n'
    fi
done

# Check /core*
for f in /core*; do
    if [ -f "$f" ] 2>/dev/null; then
        CORE_FILES="${CORE_FILES}${f}"$'\n'
    fi
done

# Trim trailing newline and count
CORE_FILES=$(echo -n "$CORE_FILES" | sed '/^$/d')
if [ -n "$CORE_FILES" ]; then
    CORE_COUNT=$(echo "$CORE_FILES" | wc -l)
else
    CORE_COUNT=0
fi

echo "Core dump check: found ${CORE_COUNT} file(s)"

# Truncate file list for details (avoid huge JSON)
CORE_LIST=$(echo "$CORE_FILES" | head -20)

details=$(jq -cn \
    --argjson count "$CORE_COUNT" \
    --arg files "$CORE_LIST" \
    --argjson hb_age "$HB_AGE" \
    '{core_count: $count, core_files: $files, heartbeat_age_s: $hb_age}')

if [ "$CORE_COUNT" -eq 0 ]; then
    sdk_always true "$ASSERTION_NAME" "$details"
else
    echo "CORE DUMP FILES FOUND: ${CORE_FILES}"
    sdk_always false "$ASSERTION_NAME" "$details"
fi

exit 0
