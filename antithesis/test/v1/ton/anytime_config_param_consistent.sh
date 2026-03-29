#!/usr/bin/env bash

# Anytime driver: ConfigParam consistency check under fault injection.
# Verifies that critical blockchain configuration parameters remain internally
# consistent even during active faults. ConfigParam 34 (current validator set)
# and related params are the most sensitive — corruption could cause consensus
# failure or invalid elections.
#
# Skip gracefully when infrastructure is unavailable (no false positives).

source "$(dirname "$0")/helper_sdk.sh"

ALWAYS_NAME="Validator set config is internally consistent"
SOMETIMES_NAME="Config params queried successfully during faults"
STATE_FILE="/shared/_config_validator_count"

VALIDATOR_HOST="${VALIDATOR_HOST:-ton-validator}"
LITE_PORT="${LITE_PORT:-30003}"
LITE_CONFIG="/shared/liteserver.config.json"
HB_FILE="/shared/validator_heartbeat"

# Heartbeat freshness threshold (seconds)
HB_FRESHNESS_THRESHOLD=60

# Catalog both assertions up front
sdk_catalog_always  "$ALWAYS_NAME"
sdk_catalog_sometimes "$SOMETIMES_NAME"

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

# --- Helper: run lite-client getconfig ---
# Args: <param_number>
# Returns: raw output from lite-client, or empty on failure

query_config() {
    local param="$1"
    timeout 10 lite-client \
        -v 1 \
        -a "${VALIDATOR_IP}:${LITE_PORT}" \
        -C "${LITE_CONFIG}" \
        -c "getconfig ${param}" \
        -c 'quit' 2>&1 || true
}

# --- Query ConfigParam 34 (current validator set) ---

echo "Querying ConfigParam 34 (current validator set)..."
OUTPUT_34=$(query_config 34)

PARAM34_OK=false
VALIDATOR_COUNT=""
TOTAL_WEIGHT=""

if [ -n "${OUTPUT_34}" ]; then
    # Parse validator count: look for "total_weight:" and "total:" fields
    # ConfigParam 34 output includes lines like:
    #   cur_validators:(validators_ext total:3 ...  total_weight:30 ...
    VALIDATOR_COUNT=$(echo "${OUTPUT_34}" | grep -oP 'total:\K[0-9]+' | head -1 || true)
    TOTAL_WEIGHT=$(echo "${OUTPUT_34}" | grep -oP 'total_weight:\K[0-9]+' | head -1 || true)

    if [ -n "${VALIDATOR_COUNT}" ] && [ -n "${TOTAL_WEIGHT}" ]; then
        PARAM34_OK=true
        echo "  ConfigParam 34: validator_count=${VALIDATOR_COUNT}, total_weight=${TOTAL_WEIGHT}"
    else
        echo "  ConfigParam 34: returned data but could not parse validator_count/total_weight"
        echo "  Raw output (last 20 lines):"
        echo "${OUTPUT_34}" | tail -20
    fi
else
    echo "  ConfigParam 34: query returned empty output"
fi

# --- Query ConfigParam 28 (catchain config) ---

echo "Querying ConfigParam 28 (catchain config)..."
OUTPUT_28=$(query_config 28)

PARAM28_OK=false

if [ -n "${OUTPUT_28}" ]; then
    # ConfigParam 28 contains catchain parameters; just verify it's parseable
    # Look for known fields like "mc_catchain_lifetime:" or "shard_catchain_lifetime:"
    if echo "${OUTPUT_28}" | grep -qE '(catchain_lifetime|mc_catchain_lifetime|shard_catchain_lifetime)'; then
        PARAM28_OK=true
        echo "  ConfigParam 28: catchain config parsed successfully"
    elif echo "${OUTPUT_28}" | grep -qE 'ConfigParam\(28\)'; then
        # Config param exists but may have different format
        PARAM28_OK=true
        echo "  ConfigParam 28: present (alternate format)"
    else
        echo "  ConfigParam 28: returned data but could not find expected fields"
    fi
else
    echo "  ConfigParam 28: query returned empty output"
fi

# --- Query ConfigParam 30 (simplex consensus config) ---

echo "Querying ConfigParam 30 (simplex consensus config)..."
OUTPUT_30=$(query_config 30)

PARAM30_OK=false

if [ -n "${OUTPUT_30}" ]; then
    # ConfigParam 30 contains NewConsensusConfigAll / simplex consensus parameters.
    # Known field names include: consensus_config, new_consensus_config, target_rate,
    # new_catchain, NewCatchain, slots_per_leader_window, first_block_timeout_ms.
    # Use a lenient pattern — if the param is present in any recognisable form, treat as OK.
    if echo "${OUTPUT_30}" | grep -qE '(consensus_config|target_rate|new_catchain|NewCatchain|slots_per_leader|first_block_timeout)'; then
        PARAM30_OK=true
        echo "  ConfigParam 30: simplex consensus config parsed successfully"
    elif echo "${OUTPUT_30}" | grep -qE 'ConfigParam\(30\)'; then
        # Param present but in an alternate / future format
        PARAM30_OK=true
        echo "  ConfigParam 30: present (alternate format)"
    else
        echo "  ConfigParam 30: returned data but could not find expected fields"
        echo "  Raw output (last 10 lines):"
        echo "${OUTPUT_30}" | tail -10
    fi
else
    echo "  ConfigParam 30: query returned empty output"
fi

# --- Query ConfigParam 15 (election params) ---

echo "Querying ConfigParam 15 (election params)..."
OUTPUT_15=$(query_config 15)

PARAM15_OK=false

if [ -n "${OUTPUT_15}" ]; then
    # ConfigParam 15 contains election timing parameters
    # Look for known fields like "elections_start_before:" or "validators_elected_for:"
    if echo "${OUTPUT_15}" | grep -qE '(validators_elected_for|elections_start_before|elections_end_before|stake_held_for)'; then
        PARAM15_OK=true
        echo "  ConfigParam 15: election params parsed successfully"
    elif echo "${OUTPUT_15}" | grep -qE 'ConfigParam\(15\)'; then
        PARAM15_OK=true
        echo "  ConfigParam 15: present (alternate format)"
    else
        echo "  ConfigParam 15: returned data but could not find expected fields"
    fi
else
    echo "  ConfigParam 15: query returned empty output"
fi

# --- Query ConfigParam 36 (next validator set, optional) ---

echo "Querying ConfigParam 36 (next validator set)..."
OUTPUT_36=$(query_config 36)

PARAM36_OK=false
NEXT_VALIDATOR_COUNT=""

if [ -n "${OUTPUT_36}" ]; then
    NEXT_VALIDATOR_COUNT=$(echo "${OUTPUT_36}" | grep -oP 'total:\K[0-9]+' | head -1 || true)
    if [ -n "${NEXT_VALIDATOR_COUNT}" ]; then
        PARAM36_OK=true
        echo "  ConfigParam 36: next_validator_count=${NEXT_VALIDATOR_COUNT}"
    else
        # ConfigParam 36 may legitimately not exist (no pending election)
        if echo "${OUTPUT_36}" | grep -qiE '(not found|no value|empty)'; then
            echo "  ConfigParam 36: not set (no pending election), OK"
        else
            echo "  ConfigParam 36: returned data but could not parse"
        fi
    fi
else
    echo "  ConfigParam 36: query returned empty output (may not exist)"
fi

# --- If none of the queries succeeded, skip (all timed out under fault) ---

if [ "${PARAM34_OK}" = "false" ] && [ "${PARAM28_OK}" = "false" ] && [ "${PARAM15_OK}" = "false" ] && [ "${PARAM30_OK}" = "false" ]; then
    echo "All config param queries failed (likely under heavy fault), skipping"
    exit 0
fi

# --- Consistency validation ---

CONSISTENT=true
FAIL_REASONS=""

# Check 1: If ConfigParam 34 was parseable, validate ranges
if [ "${PARAM34_OK}" = "true" ]; then
    # Validator count must be >= 1 and <= 100
    if [ "${VALIDATOR_COUNT}" -lt 1 ] || [ "${VALIDATOR_COUNT}" -gt 100 ]; then
        CONSISTENT=false
        FAIL_REASONS="${FAIL_REASONS}validator_count=${VALIDATOR_COUNT} out of range [1,100]; "
    fi

    # Total weight must be > 0
    if [ "${TOTAL_WEIGHT}" -le 0 ]; then
        CONSISTENT=false
        FAIL_REASONS="${FAIL_REASONS}total_weight=${TOTAL_WEIGHT} must be >0; "
    fi
fi

# Check 2: If ConfigParam 36 parsed, next validator count must also be >= 1
if [ "${PARAM36_OK}" = "true" ] && [ -n "${NEXT_VALIDATOR_COUNT}" ]; then
    if [ "${NEXT_VALIDATOR_COUNT}" -lt 1 ]; then
        CONSISTENT=false
        FAIL_REASONS="${FAIL_REASONS}next_validator_count=${NEXT_VALIDATOR_COUNT} must be >=1; "
    fi
fi

# Check 3: If ConfigParam 34 is queryable but ConfigParam 30 is completely absent, that's
# a structural inconsistency — the simplex consensus config should always be present.
if [ "${PARAM34_OK}" = "true" ] && [ -z "${OUTPUT_30}" ]; then
    CONSISTENT=false
    FAIL_REASONS="${FAIL_REASONS}ConfigParam 30 missing while ConfigParam 34 is queryable; "
fi

# Check 4: If ConfigParam 34 returned data but was unparseable (garbled), that's a failure
if [ -n "${OUTPUT_34}" ] && [ "${PARAM34_OK}" = "false" ]; then
    # Only fail if the output looks like it should have had data (not a timeout/connection error)
    if echo "${OUTPUT_34}" | grep -qiE '(cur_validators|ConfigParam\(34\))'; then
        CONSISTENT=false
        FAIL_REASONS="${FAIL_REASONS}ConfigParam 34 present but garbled; "
    fi
fi

# --- Build details JSON ---

DETAILS=$(jq -cn \
    --argjson param34_ok "$([ "${PARAM34_OK}" = "true" ] && echo true || echo false)" \
    --argjson param28_ok "$([ "${PARAM28_OK}" = "true" ] && echo true || echo false)" \
    --argjson param30_ok "$([ "${PARAM30_OK}" = "true" ] && echo true || echo false)" \
    --argjson param15_ok "$([ "${PARAM15_OK}" = "true" ] && echo true || echo false)" \
    --argjson param36_ok "$([ "${PARAM36_OK}" = "true" ] && echo true || echo false)" \
    --arg validator_count "${VALIDATOR_COUNT:-null}" \
    --arg total_weight "${TOTAL_WEIGHT:-null}" \
    --arg next_validator_count "${NEXT_VALIDATOR_COUNT:-null}" \
    --argjson consistent "$([ "${CONSISTENT}" = "true" ] && echo true || echo false)" \
    --arg fail_reasons "${FAIL_REASONS}" \
    '{param34_ok: $param34_ok, param28_ok: $param28_ok, param30_ok: $param30_ok,
      param15_ok: $param15_ok, param36_ok: $param36_ok,
      validator_count: $validator_count, total_weight: $total_weight,
      next_validator_count: $next_validator_count, consistent: $consistent,
      fail_reasons: $fail_reasons}')

# --- Emit assertions ---

if [ "${CONSISTENT}" = "true" ]; then
    echo "PASS: Validator set config is internally consistent"
    sdk_always true "$ALWAYS_NAME" "$DETAILS"
else
    echo "FAIL: Config inconsistency detected: ${FAIL_REASONS}"
    sdk_always false "$ALWAYS_NAME" "$DETAILS"
fi

# Sometimes: all 4 core config queries returned valid parseable data (incl. param 30)
if [ "${PARAM34_OK}" = "true" ] && [ "${PARAM28_OK}" = "true" ] && [ "${PARAM15_OK}" = "true" ] && [ "${PARAM30_OK}" = "true" ]; then
    echo "All 4 config param queries returned valid data (including ConfigParam 30)"
    sdk_sometimes true "$SOMETIMES_NAME" "$DETAILS"
fi

# --- State tracking: log validator count changes ---

if [ "${PARAM34_OK}" = "true" ] && [ -n "${VALIDATOR_COUNT}" ]; then
    PREV_COUNT=""
    if [ -f "${STATE_FILE}" ]; then
        PREV_COUNT=$(cat "${STATE_FILE}" 2>/dev/null | tr -d '[:space:]')
    fi

    echo "${VALIDATOR_COUNT}" > "${STATE_FILE}"

    if [ -n "${PREV_COUNT}" ] && [ "${PREV_COUNT}" != "${VALIDATOR_COUNT}" ]; then
        echo "NOTICE: Validator count changed from ${PREV_COUNT} to ${VALIDATOR_COUNT} (elections may have occurred)"
    fi
fi

exit 0
