#!/usr/bin/env bash

# First driver: Validator initial state is valid before faults
# Runs exactly once before Antithesis begins fault injection.
# Validates that the validator started correctly and is in a known-good state.
# Retries for up to 120 seconds since the validator may still be starting up.

source "$(dirname "$0")/helper_sdk.sh"

ASSERTION_NAME="Validator initial state is valid before faults"
VALIDATOR_HOST="${VALIDATOR_HOST:-ton-validator}"
VALIDATOR_PORT="${VALIDATOR_PORT:-30001}"
CONSOLE_PORT="${CONSOLE_PORT:-30002}"
LITE_PORT="${LITE_PORT:-30003}"
HEARTBEAT_MAX_AGE=60
MAX_RETRIES=24
RETRY_SLEEP=5

for attempt in $(seq 1 "$MAX_RETRIES"); do
    echo "Attempt ${attempt}/${MAX_RETRIES}: Checking initial validator state..."

    CHECKS_PASSED=true
    FAILED_CHECKS=""

    # Check 1: Heartbeat file exists and is fresh
    HB_OK=false
    if [ -f /shared/validator_heartbeat ]; then
        HB_TS=$(cat /shared/validator_heartbeat 2>/dev/null || true)
        HB_TS=$(echo "$HB_TS" | tr -d '[:space:]')
        NOW=$(date +%s)
        if [[ "$HB_TS" =~ ^[0-9]+$ ]]; then
            AGE=$((NOW - HB_TS))
            if [ "$AGE" -le "$HEARTBEAT_MAX_AGE" ]; then
                HB_OK=true
            fi
        fi
    fi
    if [ "$HB_OK" = "false" ]; then
        CHECKS_PASSED=false
        FAILED_CHECKS="${FAILED_CHECKS},heartbeat"
    fi

    # Check 2: UDP port reachable
    UDP_OK=false
    if nc -z -w 2 -u "${VALIDATOR_HOST}" "${VALIDATOR_PORT}" 2>/dev/null; then
        UDP_OK=true
    fi
    if [ "$UDP_OK" = "false" ]; then
        CHECKS_PASSED=false
        FAILED_CHECKS="${FAILED_CHECKS},udp_port"
    fi

    # Check 3: Console TCP port reachable
    CONSOLE_OK=false
    if nc -z -w 2 "${VALIDATOR_HOST}" "${CONSOLE_PORT}" 2>/dev/null; then
        CONSOLE_OK=true
    fi
    if [ "$CONSOLE_OK" = "false" ]; then
        CHECKS_PASSED=false
        FAILED_CHECKS="${FAILED_CHECKS},console_port"
    fi

    # Check 4: Liteserver TCP port reachable
    LITE_OK=false
    if nc -z -w 2 "${VALIDATOR_HOST}" "${LITE_PORT}" 2>/dev/null; then
        LITE_OK=true
    fi
    if [ "$LITE_OK" = "false" ]; then
        CHECKS_PASSED=false
        FAILED_CHECKS="${FAILED_CHECKS},lite_port"
    fi

    # Check 5: Config is valid JSON
    CONFIG_OK=false
    CONFIG_VAL=$(cat /shared/validator_config_valid 2>/dev/null || true)
    CONFIG_VAL=$(echo "$CONFIG_VAL" | tr -d '[:space:]')
    if [ "$CONFIG_VAL" = "1" ]; then
        CONFIG_OK=true
    fi
    if [ "$CONFIG_OK" = "false" ]; then
        CHECKS_PASSED=false
        FAILED_CHECKS="${FAILED_CHECKS},config_valid"
    fi

    # Check 6: DB size is > 0
    DB_OK=false
    DB_SIZE=$(cat /shared/validator_db_size 2>/dev/null || true)
    DB_SIZE=$(echo "$DB_SIZE" | tr -d '[:space:]')
    if [[ "$DB_SIZE" =~ ^[0-9]+$ ]] && [ "$DB_SIZE" -gt 0 ]; then
        DB_OK=true
    fi
    if [ "$DB_OK" = "false" ]; then
        CHECKS_PASSED=false
        FAILED_CHECKS="${FAILED_CHECKS},db_size"
    fi

    # Check 7: Keyring has entries
    KEYRING_OK=false
    KEYRING_COUNT=$(cat /shared/validator_keyring_count 2>/dev/null || true)
    KEYRING_COUNT=$(echo "$KEYRING_COUNT" | tr -d '[:space:]')
    if [[ "$KEYRING_COUNT" =~ ^[0-9]+$ ]] && [ "$KEYRING_COUNT" -gt 0 ]; then
        KEYRING_OK=true
    fi
    if [ "$KEYRING_OK" = "false" ]; then
        CHECKS_PASSED=false
        FAILED_CHECKS="${FAILED_CHECKS},keyring"
    fi

    # Strip leading comma from failed checks list
    FAILED_CHECKS="${FAILED_CHECKS#,}"

    if [ "$CHECKS_PASSED" = "true" ]; then
        echo "PASS: All initial state checks passed on attempt ${attempt}"
        DETAILS=$(jq -cn \
            --argjson hb "$HB_OK" --argjson udp "$UDP_OK" \
            --argjson console "$CONSOLE_OK" --argjson lite "$LITE_OK" \
            --argjson config "$CONFIG_OK" --argjson db "$DB_OK" \
            --argjson keyring "$KEYRING_OK" --argjson attempt "$attempt" \
            '{heartbeat: $hb, udp_port: $udp, console_port: $console, lite_port: $lite, config_valid: $config, db_size_positive: $db, keyring_nonempty: $keyring, attempt: $attempt}')
        sdk_always true "$ASSERTION_NAME" "$DETAILS"
        exit 0
    fi

    if [ "$attempt" -lt "$MAX_RETRIES" ]; then
        echo "Checks failed (${FAILED_CHECKS}), retrying in ${RETRY_SLEEP}s..."
        sleep "$RETRY_SLEEP"
    fi
done

# All retries exhausted — emit failure
echo "FAIL: Initial state checks failed after ${MAX_RETRIES} attempts: ${FAILED_CHECKS}"
DETAILS=$(jq -cn \
    --argjson hb "$HB_OK" --argjson udp "$UDP_OK" \
    --argjson console "$CONSOLE_OK" --argjson lite "$LITE_OK" \
    --argjson config "$CONFIG_OK" --argjson db "$DB_OK" \
    --argjson keyring "$KEYRING_OK" --argjson attempts "$MAX_RETRIES" \
    --arg failed "$FAILED_CHECKS" \
    '{heartbeat: $hb, udp_port: $udp, console_port: $console, lite_port: $lite, config_valid: $config, db_size_positive: $db, keyring_nonempty: $keyring, attempts: $attempts, failed_checks: $failed}')
sdk_always false "$ASSERTION_NAME" "$DETAILS"
exit 0
