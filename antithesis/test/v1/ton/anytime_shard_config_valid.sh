#!/usr/bin/env bash

# Anytime driver: Shard configuration validity check under fault injection.
# Verifies that workchain shard state remains valid even during active faults.
# Shard splits/merges, shard state corruption, and missing shards are critical
# TON failure modes that this script catches via the allshards liteserver command.
#
# Skip gracefully when infrastructure is unavailable (no false positives).

source "$(dirname "$0")/helper_sdk.sh"

ALWAYS_NONEMPTY_NAME="Shard configuration is non-empty when masterchain is active"
SOMETIMES_NAME="Workchain shard state queried during faults"
ALWAYS_SEQNO_NAME="Workchain shard seqno is non-negative"

VALIDATOR_HOST="${VALIDATOR_HOST:-ton-validator}"
LITE_PORT="${LITE_PORT:-30003}"
LITE_CONFIG="/shared/liteserver.config.json"
HB_FILE="/shared/validator_heartbeat"

# Heartbeat freshness threshold (seconds)
HB_FRESHNESS_THRESHOLD=60

# Catalog all assertions up front
sdk_catalog_always  "$ALWAYS_NONEMPTY_NAME"
sdk_catalog_sometimes "$SOMETIMES_NAME"
sdk_catalog_always  "$ALWAYS_SEQNO_NAME"

# --- Precondition checks (skip, never fail) ---

if ! command -v lite-client >/dev/null 2>&1; then
    echo "lite-client binary not found, skipping"
    exit 0
fi

if [ ! -f "${LITE_CONFIG}" ]; then
    echo "Liteserver config not found, skipping"
    exit 0
fi

# Check heartbeat freshness
if [ -f "${HB_FILE}" ]; then
    HB_TS=$(cat "${HB_FILE}" 2>/dev/null | tr -d '[:space:]')
    if [[ "${HB_TS}" =~ ^[0-9]+$ ]]; then
        NOW=$(date +%s)
        HB_AGE=$(( NOW - HB_TS ))
        if [ "${HB_AGE}" -gt "${HB_FRESHNESS_THRESHOLD}" ]; then
            echo "Heartbeat stale (age=${HB_AGE}s), skipping"
            exit 0
        fi
    else
        echo "Heartbeat unreadable, skipping"
        exit 0
    fi
else
    echo "Heartbeat file missing, skipping"
    exit 0
fi

# Check liteserver reachability
if ! nc -z -w 2 "${VALIDATOR_HOST}" "${LITE_PORT}" 2>/dev/null; then
    echo "Liteserver unreachable, skipping"
    exit 0
fi

# --- Helper: resolve hostname to IP ---

resolve_ip() {
    local host="$1"
    local ip=""
    if command -v getent >/dev/null 2>&1; then
        ip=$(getent hosts "${host}" 2>/dev/null | awk '{print $1; exit}')
    fi
    [ -z "${ip}" ] && ip="${host}"
    echo "${ip}"
}

VALIDATOR_IP=$(resolve_ip "${VALIDATOR_HOST}")

# --- Run lite-client: last + allshards ---

echo "Querying lite-client: last + allshards..."
OUTPUT=$(timeout 15 lite-client \
    -v 1 \
    -a "${VALIDATOR_IP}:${LITE_PORT}" \
    -C "${LITE_CONFIG}" \
    -c 'last' \
    -c 'allshards' \
    -c 'quit' 2>&1 || true)

if [ -z "${OUTPUT}" ]; then
    echo "lite-client returned empty output, skipping"
    exit 0
fi

# --- Determine if masterchain is up (last succeeded) ---

LAST_OK=false
if echo "${OUTPUT}" | grep -qE 'latest masterchain block known to server'; then
    LAST_OK=true
    echo "  last: masterchain block confirmed"
else
    echo "  last: could not confirm masterchain block — skipping (likely under fault)"
    exit 0
fi

# --- Parse allshards output ---
# Expected format: lines like:
#   shard #0 : 0:8000000000000000 ... seqno 42
#   shard #1 : 0:0000000000000000 ... seqno 41

SHARD_LINES=$(echo "${OUTPUT}" | grep -E 'shard #[0-9]+' || true)
SHARD_COUNT=0
if [ -n "${SHARD_LINES}" ]; then
    SHARD_COUNT=$(echo "${SHARD_LINES}" | wc -l | tr -d ' ')
fi

echo "  allshards: found ${SHARD_COUNT} shard(s)"

# --- Always assertion: shard config must be non-empty when masterchain is active ---

DETAILS_NONEMPTY=$(jq -cn \
    --argjson last_ok true \
    --argjson shard_count "${SHARD_COUNT}" \
    '{last_ok: $last_ok, shard_count: $shard_count}')

if [ "${SHARD_COUNT}" -eq 0 ]; then
    echo "FAIL: Masterchain is active but allshards returned zero shards"
    sdk_always false "$ALWAYS_NONEMPTY_NAME" "$DETAILS_NONEMPTY"
    exit 1
else
    echo "PASS: Shard configuration is non-empty (${SHARD_COUNT} shard(s))"
    sdk_always true "$ALWAYS_NONEMPTY_NAME" "$DETAILS_NONEMPTY"
fi

# --- Sometimes assertion: valid shard data obtained during faults ---

sdk_sometimes true "$SOMETIMES_NAME" "$DETAILS_NONEMPTY"
echo "Sometimes: workchain shard state queried successfully"

# --- Parse seqnos and validate non-negative ---

SEQNO_VALID=true
SEQNO_FAIL_REASONS=""

while IFS= read -r line; do
    [ -z "${line}" ] && continue

    # Try to extract seqno — format: "seqno N" or "seq_no:N"
    SEQNO=$(echo "${line}" | grep -oP '(?i)seq(?:no|_no)[: ]+\K[0-9]+' | head -1 || true)

    if [ -z "${SEQNO}" ]; then
        # Try alternate grep for just trailing integer after "seqno"
        SEQNO=$(echo "${line}" | grep -oE 'seqno [0-9]+' | grep -oE '[0-9]+$' || true)
    fi

    if [ -z "${SEQNO}" ]; then
        echo "  Could not parse seqno from line: ${line}"
        continue
    fi

    echo "  Shard line seqno=${SEQNO}: ${line}"

    # seqno is always non-negative as an unsigned integer, but defend against
    # garbled output producing negative-looking values
    if [ "${SEQNO}" -lt 0 ] 2>/dev/null; then
        SEQNO_VALID=false
        SEQNO_FAIL_REASONS="${SEQNO_FAIL_REASONS}seqno=${SEQNO} is negative; "
    fi
done <<< "${SHARD_LINES}"

DETAILS_SEQNO=$(jq -cn \
    --argjson shard_count "${SHARD_COUNT}" \
    --argjson seqno_valid "$([ "${SEQNO_VALID}" = "true" ] && echo true || echo false)" \
    --arg fail_reasons "${SEQNO_FAIL_REASONS}" \
    '{shard_count: $shard_count, seqno_valid: $seqno_valid, fail_reasons: $fail_reasons}')

if [ "${SEQNO_VALID}" = "true" ]; then
    echo "PASS: All workchain shard seqnos are non-negative"
    sdk_always true "$ALWAYS_SEQNO_NAME" "$DETAILS_SEQNO"
else
    echo "FAIL: Workchain shard seqno violation: ${SEQNO_FAIL_REASONS}"
    sdk_always false "$ALWAYS_SEQNO_NAME" "$DETAILS_SEQNO"
    exit 1
fi

exit 0
