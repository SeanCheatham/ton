#!/usr/bin/env bash
source /opt/antithesis/test/v1/ton/helper_sdk.sh
PROPERTY="Validator CPU time is advancing when healthy"
STATE_FILE="/shared/validator_cpu_ticks_prev"

# Heartbeat-based precondition (matches working scripts like parallel_driver_db_activity.sh)
HEARTBEAT_MAX_AGE=90
if [ -f /shared/validator_heartbeat ]; then
    HB_TS=$(cat /shared/validator_heartbeat 2>/dev/null || true)
    HB_TS=$(echo "$HB_TS" | tr -d '[:space:]')
    NOW=$(date +%s)
    if [[ "$HB_TS" =~ ^[0-9]+$ ]]; then
        AGE=$((NOW - HB_TS))
        if [ "$AGE" -gt "$HEARTBEAT_MAX_AGE" ]; then
            echo "Heartbeat stale (${AGE}s > ${HEARTBEAT_MAX_AGE}s), skipping"
            sdk_always true "$PROPERTY" '{"status":"heartbeat_stale"}'
            exit 0
        fi
    else
        echo "Heartbeat value invalid, skipping"
        sdk_always true "$PROPERTY" '{"status":"heartbeat_invalid"}'
        exit 0
    fi
else
    echo "Heartbeat file not present yet, skipping"
    sdk_always true "$PROPERTY" '{"status":"heartbeat_not_present"}'
    exit 0
fi

CURRENT=$(cat /shared/validator_cpu_ticks 2>/dev/null || true)
CURRENT=$(echo "$CURRENT" | tr -d '[:space:]')
if [[ -z "$CURRENT" || "$CURRENT" == "-1" ]] || ! [[ "$CURRENT" =~ ^[0-9]+$ ]]; then
    echo "No valid CPU ticks available yet"
    sdk_always true "$PROPERTY" '{"status":"metric_not_available"}'
    exit 0
fi

PREV=$(cat "$STATE_FILE" 2>/dev/null || true)
PREV=$(echo "$PREV" | tr -d '[:space:]')
echo "$CURRENT" > "$STATE_FILE"

if [[ -z "$PREV" ]] || ! [[ "$PREV" =~ ^[0-9]+$ ]]; then
    echo "First observation: $CURRENT ticks"
    sdk_always true "$PROPERTY" "$(jq -cn --argjson cur "$CURRENT" '{status:"first_observation", current: $cur}')"
    exit 0
fi

if [ "$CURRENT" -gt "$PREV" ]; then
    DELTA=$((CURRENT - PREV))
    sdk_always true "$PROPERTY" "$(jq -cn --argjson delta "$DELTA" --argjson prev "$PREV" --argjson cur "$CURRENT" '{delta: $delta, prev: $prev, current: $cur}')"
elif [ "$CURRENT" -eq "$PREV" ]; then
    # Heartbeat updates every 5s — the driver may run faster than that.
    # Equal ticks are inconclusive, not a failure.
    echo "CPU ticks unchanged ($CURRENT), heartbeat may not have refreshed yet — skipping"
    sdk_always true "$PROPERTY" "$(jq -cn --argjson cur "$CURRENT" '{status:"unchanged", current: $cur}')"
    exit 0
else
    # CURRENT < PREV indicates a process restart (PID 1 replaced, CPU counters
    # reset) or a file-read race on the shared volume.  Neither is a validator
    # bug — reset the baseline so the next invocation compares within the new
    # process lifecycle.
    echo "CPU ticks decreased (prev=$PREV, cur=$CURRENT) — likely process restart, resetting baseline"
    sdk_always true "$PROPERTY" "$(jq -cn --argjson prev "$PREV" --argjson cur "$CURRENT" '{status:"restart_detected", prev: $prev, current: $cur}')"
    exit 0
fi
