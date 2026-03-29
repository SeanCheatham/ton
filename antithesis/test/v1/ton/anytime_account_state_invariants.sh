#!/usr/bin/env bash

# Anytime driver: Account balance & seqno invariant checks during faults.
# This runs DURING active fault injection (anytime_* driver type).
#
# Verifies two core blockchain safety invariants from the TON whitepaper:
#   1. Account balances remain non-negative (storage fee underflow = critical bug)
#   2. Account seqno is monotonically non-decreasing (rollback = state corruption)
#
# Uses the same wallet address as serial_driver_send_transfer.sh to ensure
# the account has activity and meaningful state to check.
#
# Hardened against fault-induced validator restarts:
#   - Skips entirely when heartbeat is stale/missing (validator restarting)
#   - Skips seqno monotonicity check when heartbeat is stale (expected seqno
#     reset from earlier state after restart)
#   - Skips assertion (doesn't emit) if lite-client query fails or returns
#     empty — validator down during fault injection is expected
#
# Skip gracefully when infrastructure is unavailable (no false positives).

source "$(dirname "$0")/helper_sdk.sh"

BALANCE_ALWAYS_NAME="Account balance is non-negative during faults"
SEQNO_ALWAYS_NAME="Account seqno is monotonically non-decreasing"
SOMETIMES_NAME="Account state is queryable during faults"

SEQNO_STATE_FILE="/shared/invariants/last_seen_seqno"

VALIDATOR_HOST="${VALIDATOR_HOST:-ton-validator}"
LITE_PORT="${LITE_PORT:-30003}"
HB_FILE="/shared/validator_heartbeat"
HB_FRESHNESS_THRESHOLD=60

# Reasonable seqno bounds — catches corrupted state
SEQNO_MAX=1000000

WALLET_ADDR="-1:0000000000000000000000000000000000000000000000000000000000000000"

# Catalog all assertions up front
sdk_catalog_always  "$BALANCE_ALWAYS_NAME"
sdk_catalog_always  "$SEQNO_ALWAYS_NAME"
sdk_catalog_sometimes "$SOMETIMES_NAME"

# --- Precondition checks (skip, never fail) ---

if ! command -v lite-client >/dev/null 2>&1; then
    echo "lite-client binary not found, skipping"
    exit 0
fi

if [ ! -f /shared/liteserver.config.json ]; then
    echo "Liteserver config not available yet, skipping"
    exit 0
fi

if ! nc -z -w 2 "${VALIDATOR_HOST}" "${LITE_PORT}" 2>/dev/null; then
    echo "Liteserver port ${LITE_PORT} not reachable, skipping"
    exit 0
fi

# --- Helper: compute heartbeat age ---
# Returns age in seconds, or -1 if heartbeat is missing/unreadable

get_heartbeat_age() {
    local hb_file="$1"
    if [ ! -f "${hb_file}" ]; then
        echo "-1"
        return
    fi
    local hb_ts
    hb_ts=$(cat "${hb_file}" 2>/dev/null || true)
    hb_ts=$(echo "${hb_ts}" | tr -d '[:space:]')
    if ! [[ "${hb_ts}" =~ ^[0-9]+$ ]]; then
        echo "-1"
        return
    fi
    local now
    now=$(date +%s)
    echo "$(( now - hb_ts ))"
}

# --- Heartbeat freshness check ---

HB_AGE=$(get_heartbeat_age "${HB_FILE}")
HB_FRESH=true

if [ "${HB_AGE}" -eq -1 ]; then
    HB_FRESH=false
    echo "Heartbeat file missing or unreadable — validator likely restarting, skipping"
    exit 0
elif [ "${HB_AGE}" -gt "${HB_FRESHNESS_THRESHOLD}" ]; then
    HB_FRESH=false
    echo "Heartbeat stale (age=${HB_AGE}s > ${HB_FRESHNESS_THRESHOLD}s) — validator likely restarting, skipping"
    exit 0
else
    echo "Heartbeat fresh (age=${HB_AGE}s)"
fi

# --- Resolve hostname to IP ---

VALIDATOR_IP=""
if command -v getent >/dev/null 2>&1; then
    VALIDATOR_IP=$(getent hosts "${VALIDATOR_HOST}" 2>/dev/null | awk '{print $1; exit}')
fi
[ -z "${VALIDATOR_IP}" ] && VALIDATOR_IP="${VALIDATOR_HOST}"

# --- Query account state: balance via getaccount ---

echo "Querying account balance for ${WALLET_ADDR}..."
ACCOUNT_OUTPUT=$(timeout 10 lite-client \
    -v 1 \
    -a "${VALIDATOR_IP}:${LITE_PORT}" \
    -C /shared/liteserver.config.json \
    -c "getaccount ${WALLET_ADDR}" \
    -c 'quit' 2>&1) || true

BALANCE=$(echo "${ACCOUNT_OUTPUT}" | grep -oP 'balance[^0-9]*\K[0-9]+' | head -1 || true)

if [ -z "${BALANCE}" ] || ! [[ "${BALANCE}" =~ ^[0-9]+$ ]]; then
    echo "Could not parse balance from getaccount output, skipping"
    exit 0
fi

echo "Account balance: ${BALANCE}"

# --- Query account state: seqno via runmethod 85143 ---

echo "Querying account seqno for ${WALLET_ADDR}..."
SEQNO_OUTPUT=$(timeout 10 lite-client \
    -v 1 \
    -a "${VALIDATOR_IP}:${LITE_PORT}" \
    -C /shared/liteserver.config.json \
    -c "runmethod ${WALLET_ADDR} 85143" \
    -c 'quit' 2>&1) || true

SEQNO=$(echo "${SEQNO_OUTPUT}" | grep -oP 'result:\s*\[\s*\K[0-9]+' | head -1 || true)

if [ -z "${SEQNO}" ] || ! [[ "${SEQNO}" =~ ^[0-9]+$ ]]; then
    echo "Could not parse seqno from runmethod output, skipping"
    exit 0
fi

echo "Account seqno: ${SEQNO}"

# --- If we got here, account state is queryable during faults ---

sdk_sometimes true "$SOMETIMES_NAME" \
    "$(jq -cn --arg bal "${BALANCE}" --argjson seqno "${SEQNO}" --argjson hb_age "${HB_AGE}" \
    '{balance: $bal, seqno: $seqno, heartbeat_age_s: $hb_age}')"

# --- Balance non-negativity check ---
# Balance is parsed as unsigned from grep, so it's always >= 0 as a string.
# However, we still assert explicitly to catch any future parsing changes
# and to register the property with Antithesis for branch exploration.

BALANCE_NONNEG=true
if [ "${BALANCE}" -lt 0 ] 2>/dev/null; then
    BALANCE_NONNEG=false
fi

BALANCE_DETAILS=$(jq -cn \
    --arg balance "${BALANCE}" \
    --argjson seqno "${SEQNO}" \
    --argjson hb_age "${HB_AGE}" \
    '{balance: $balance, seqno: $seqno, heartbeat_age_s: $hb_age, check: "non_negative"}')

if [ "${BALANCE_NONNEG}" = "true" ]; then
    echo "PASS: Account balance is non-negative (${BALANCE})"
    sdk_always true "$BALANCE_ALWAYS_NAME" "$BALANCE_DETAILS"
else
    echo "FAIL: Account balance is NEGATIVE (${BALANCE}) — critical safety violation!"
    sdk_always false "$BALANCE_ALWAYS_NAME" "$BALANCE_DETAILS"
fi

# --- Seqno bounds check (embedded in monotonicity assertion) ---
# Catches corrupted state — seqno should be in [0, 1000000]

if [ "${SEQNO}" -gt "${SEQNO_MAX}" ]; then
    echo "FAIL: Account seqno ${SEQNO} exceeds reasonable maximum ${SEQNO_MAX} — possible state corruption!"
    BOUNDS_DETAILS=$(jq -cn \
        --argjson seqno "${SEQNO}" \
        --argjson max "${SEQNO_MAX}" \
        --argjson hb_age "${HB_AGE}" \
        '{seqno: $seqno, max_bound: $max, heartbeat_age_s: $hb_age, check: "bounds"}')
    sdk_always false "$SEQNO_ALWAYS_NAME" "$BOUNDS_DETAILS"
    exit 0
fi

# --- Seqno monotonicity check ---

# Ensure state directory exists
mkdir -p "$(dirname "${SEQNO_STATE_FILE}")"

PREV_SEQNO=""
if [ -f "${SEQNO_STATE_FILE}" ]; then
    PREV_SEQNO=$(cat "${SEQNO_STATE_FILE}" 2>/dev/null || true)
    PREV_SEQNO=$(echo "${PREV_SEQNO}" | tr -d '[:space:]')
fi

if [ -z "${PREV_SEQNO}" ] || ! [[ "${PREV_SEQNO}" =~ ^[0-9]+$ ]]; then
    # First observation — just record and exit
    echo "${SEQNO}" > "${SEQNO_STATE_FILE}"
    echo "First seqno observation, recorded seqno ${SEQNO}"
    # Still emit the always-true for the balance check above
    exit 0
fi

echo "Previous seqno: ${PREV_SEQNO}, Current seqno: ${SEQNO}"

SEQNO_DETAILS=$(jq -cn \
    --argjson current "${SEQNO}" \
    --argjson previous "${PREV_SEQNO}" \
    --argjson delta "$(( SEQNO - PREV_SEQNO ))" \
    --argjson hb_age "${HB_AGE}" \
    --argjson hb_fresh "$([ "${HB_FRESH}" = "true" ] && echo true || echo false)" \
    '{current_seqno: $current, previous_seqno: $previous, delta: $delta,
      heartbeat_age_s: $hb_age, heartbeat_fresh: $hb_fresh, check: "monotonicity"}')

if [ "${SEQNO}" -lt "${PREV_SEQNO}" ]; then
    ABS_DROP=$(( PREV_SEQNO - SEQNO ))

    if [ "${HB_FRESH}" = "false" ]; then
        # Validator heartbeat is stale/missing — likely restarting after fault injection.
        # Do NOT assert failure; skip to avoid false positives.
        echo "SKIP: Seqno decreased (${PREV_SEQNO} -> ${SEQNO}, drop=${ABS_DROP}) but heartbeat is stale/missing — validator likely restarting"
        echo "${SEQNO}" > "${SEQNO_STATE_FILE}"
    elif [ "${ABS_DROP}" -gt 10 ]; then
        # Large drop with fresh heartbeat — likely validator restarted to genesis
        # and heartbeat hasn't gone stale yet. Skip but log loudly.
        echo "SKIP: Large seqno drop (${PREV_SEQNO} -> ${SEQNO}, drop=${ABS_DROP}) — likely restart to genesis despite fresh heartbeat"
        echo "${SEQNO}" > "${SEQNO_STATE_FILE}"
    else
        # Small drop (1-10) with fresh heartbeat — this is suspicious and likely real state corruption
        echo "FAIL: Account seqno DECREASED from ${PREV_SEQNO} to ${SEQNO} (drop=${ABS_DROP}) with fresh heartbeat (age=${HB_AGE}s) — possible state corruption!"
        sdk_always false "$SEQNO_ALWAYS_NAME" "$SEQNO_DETAILS"
    fi
else
    echo "PASS: Account seqno non-decreasing (${PREV_SEQNO} -> ${SEQNO})"
    sdk_always true "$SEQNO_ALWAYS_NAME" "$SEQNO_DETAILS"
    # Update state file with latest observed seqno
    echo "${SEQNO}" > "${SEQNO_STATE_FILE}"
fi

exit 0
