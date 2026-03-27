#!/usr/bin/env bash
source /opt/antithesis/test/v1/ton/helper_sdk.sh
PROPERTY="Validator is actively modifying database files"

# Heartbeat-only precondition: heartbeat freshness proves the validator process
# is actively running and metrics are valid, regardless of port status.
HEARTBEAT_MAX_AGE=90
if [ -f /shared/validator_heartbeat ]; then
    HB_TS=$(cat /shared/validator_heartbeat 2>/dev/null || true)
    HB_TS=$(echo "$HB_TS" | tr -d '[:space:]')
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

NOW=$(date +%s)

DB_MTIME=$(cat /shared/validator_db_mtime 2>/dev/null || echo "-1")

if [[ "$DB_MTIME" == "-1" || -z "$DB_MTIME" ]]; then
    echo "No DB mtime available yet, skipping"
    exit 0
fi

AGE=$((NOW - DB_MTIME))
LIMIT=120
if [ "$AGE" -le "$LIMIT" ]; then
    sdk_always true "$PROPERTY" "$(jq -cn --argjson age "$AGE" '{age_seconds: $age}')"
else
    sdk_always false "$PROPERTY" "$(jq -cn --argjson age "$AGE" --argjson limit "$LIMIT" '{age_seconds: $age, limit_seconds: $limit}')"
fi
