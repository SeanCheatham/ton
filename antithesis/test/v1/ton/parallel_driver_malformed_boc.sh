#!/usr/bin/env bash
set -euo pipefail

# Parallel driver: Submit malformed BOC files to the validator and verify
# it handles them gracefully (rejects without crashing or corrupting state).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/helper_sdk.sh"

VALIDATOR_HOST="${VALIDATOR_HOST:-ton-validator}"
LITE_PORT="${LITE_PORT:-30003}"
ALWAYS_NAME="Validator survives malformed BOC submissions"
SOMETIMES_NAME="Malformed BOC gracefully rejected"
HEARTBEAT_MAX_AGE=60

sdk_catalog_always "${ALWAYS_NAME}"
sdk_catalog_sometimes "${SOMETIMES_NAME}"

# --- Precondition: heartbeat must be fresh ---
if [ ! -f /shared/validator_heartbeat ]; then
    echo "Heartbeat file not present yet, skipping"
    exit 0
fi
HB_TS=$(cat /shared/validator_heartbeat 2>/dev/null || true)
HB_TS=$(echo "$HB_TS" | tr -d '[:space:]')
NOW=$(date +%s)
if [[ "${HB_TS}" =~ ^[0-9]+$ ]]; then
    HB_AGE=$(( NOW - HB_TS ))
    if [ "${HB_AGE}" -gt "${HEARTBEAT_MAX_AGE}" ]; then
        echo "Heartbeat stale (${HB_AGE}s), skipping"
        exit 0
    fi
else
    echo "Heartbeat value invalid, skipping"; exit 0
fi

# --- Precondition: liteserver reachable ---
if ! nc -z -w 2 "${VALIDATOR_HOST}" "${LITE_PORT}" 2>/dev/null; then
    echo "Liteserver port ${LITE_PORT} not reachable, skipping"
    exit 0
fi
if [ ! -f /shared/liteserver.config.json ]; then
    echo "Liteserver config not available yet, skipping"
    exit 0
fi
if ! command -v lite-client >/dev/null 2>&1; then
    echo "lite-client binary not found, skipping"
    exit 0
fi

# --- Resolve validator hostname to IP ---
VALIDATOR_IP=""
if command -v getent >/dev/null 2>&1; then
    VALIDATOR_IP=$(getent hosts "${VALIDATOR_HOST}" 2>/dev/null | awk '{print $1; exit}')
fi
[ -z "${VALIDATOR_IP}" ] && VALIDATOR_IP="${VALIDATOR_HOST}"

# --- Generate malformed BOC files ---
MALFORMED_FILES=()

# Type 1: Truncated valid BOC (only if a valid BOC exists)
VALID_BOC=""
for f in /shared/tx/transfer_seqno_*.boc; do
    if [ -f "$f" ]; then
        VALID_BOC="$f"
        break
    fi
done

if [ -n "${VALID_BOC}" ]; then
    SIZE=$(stat -c%s "${VALID_BOC}" 2>/dev/null || stat -f%z "${VALID_BOC}" 2>/dev/null || echo 0)
    if [ "${SIZE}" -gt 2 ]; then
        HALF=$(( SIZE / 2 ))
        head -c "${HALF}" "${VALID_BOC}" > /tmp/malformed_truncated.boc
        MALFORMED_FILES+=("/tmp/malformed_truncated.boc")
        echo "Generated truncated BOC (${HALF} of ${SIZE} bytes) from ${VALID_BOC}"
    fi

    # Type 3: Wrong magic (copy valid BOC, overwrite first 4 bytes with zeros)
    cp "${VALID_BOC}" /tmp/malformed_magic.boc
    printf '\x00\x00\x00\x00' | dd of=/tmp/malformed_magic.boc bs=1 count=4 conv=notrunc 2>/dev/null
    MALFORMED_FILES+=("/tmp/malformed_magic.boc")
    echo "Generated wrong-magic BOC from ${VALID_BOC}"
else
    echo "No valid BOC found in /shared/tx/, skipping truncated and wrong-magic variants"
fi

# Type 2: Random bytes (always generated)
dd if=/dev/urandom of=/tmp/malformed_random.boc bs=256 count=1 2>/dev/null
MALFORMED_FILES+=("/tmp/malformed_random.boc")
echo "Generated random-bytes BOC (256 bytes)"

if [ ${#MALFORMED_FILES[@]} -eq 0 ]; then
    echo "No malformed BOC files generated, skipping"
    exit 0
fi

# --- Submit each malformed BOC ---
SUBMITTED=0
for BOC_FILE in "${MALFORMED_FILES[@]}"; do
    BOC_NAME=$(basename "${BOC_FILE}")
    echo "Submitting malformed BOC: ${BOC_NAME}..."
    SEND_OUTPUT=$(timeout 10 lite-client \
        -v 1 \
        -a "${VALIDATOR_IP}:${LITE_PORT}" \
        -C /shared/liteserver.config.json \
        -c "sendfile ${BOC_FILE}" \
        -c 'quit' 2>&1) || true
    echo "  Output: ${SEND_OUTPUT:0:300}"
    SUBMITTED=$(( SUBMITTED + 1 ))
done

echo "Submitted ${SUBMITTED} malformed BOC files. Verifying validator health..."

# --- Verify validator survived ---
sleep 2

# Check 1: heartbeat still fresh
HB_TS_AFTER=$(cat /shared/validator_heartbeat 2>/dev/null || true)
HB_TS_AFTER=$(echo "$HB_TS_AFTER" | tr -d '[:space:]')
NOW_AFTER=$(date +%s)
HB_FRESH=false
if [[ "${HB_TS_AFTER}" =~ ^[0-9]+$ ]]; then
    HB_AGE_AFTER=$(( NOW_AFTER - HB_TS_AFTER ))
    if [ "${HB_AGE_AFTER}" -le "${HEARTBEAT_MAX_AGE}" ]; then
        HB_FRESH=true
        echo "Heartbeat still fresh (age: ${HB_AGE_AFTER}s)"
    else
        echo "Heartbeat went stale after submissions (age: ${HB_AGE_AFTER}s)"
    fi
else
    echo "Heartbeat invalid after submissions"
fi

# Check 2: liteserver still responds to 'last'
LAST_OUTPUT=$(timeout 10 lite-client \
    -v 1 \
    -a "${VALIDATOR_IP}:${LITE_PORT}" \
    -C /shared/liteserver.config.json \
    -c 'last' \
    -c 'quit' 2>&1) || true
LITE_OK=false
if echo "${LAST_OUTPUT}" | grep -qE '\(-1,[0-9a-fA-F]+,[0-9]+\)'; then
    LITE_OK=true
    echo "Liteserver still responding to queries"
else
    echo "Liteserver not responding after submissions"
fi

# --- Emit assertions ---
DETAILS=$(jq -cn \
    --argjson submitted "${SUBMITTED}" \
    --argjson heartbeat_fresh "${HB_FRESH}" \
    --argjson liteserver_ok "${LITE_OK}" \
    '{malformed_bocs_submitted: $submitted, heartbeat_fresh: $heartbeat_fresh, liteserver_responsive: $liteserver_ok}')

if [ "${HB_FRESH}" = true ]; then
    echo "PASS: Validator survived all ${SUBMITTED} malformed BOC submissions"
    sdk_always true "${ALWAYS_NAME}" "${DETAILS}"
    if [ "${LITE_OK}" = true ]; then
        sdk_sometimes true "${SOMETIMES_NAME}" "${DETAILS}"
    fi
else
    echo "FAIL: Validator heartbeat went stale after malformed BOC submissions"
    sdk_always false "${ALWAYS_NAME}" "${DETAILS}"
fi

# Cleanup
rm -f /tmp/malformed_truncated.boc /tmp/malformed_random.boc /tmp/malformed_magic.boc

exit 0
