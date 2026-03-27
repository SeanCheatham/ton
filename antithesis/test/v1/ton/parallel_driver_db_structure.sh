#!/usr/bin/env bash
set -euo pipefail

# Parallel driver: Validator database directory structure is intact when healthy
# When the validator heartbeat is fresh, the critical database components
# (keyring/ directory, config.json, and RocksDB metadata like CURRENT/MANIFEST)
# must exist under /var/ton-work/db/. A missing component indicates catastrophic
# data corruption or filesystem failure that other assertions (DB size, DB
# permissions, etc.) would miss because they check aggregate properties.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/helper_sdk.sh"

ASSERTION_NAME="Validator database directory structure is intact when healthy"

echo "Checking validator database directory structure..."

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

# Read DB structure status from shared volume (written by validator heartbeat loop)
if [ ! -f /shared/validator_db_structure ]; then
    echo "Metric not available yet (validator may have just restarted)"
    sdk_always true "${ASSERTION_NAME}" '{"status":"metric_not_yet_available","note":"heartbeat fresh but metric file pending"}'
    exit 0
fi

DB_STRUCTURE=$(cat /shared/validator_db_structure 2>/dev/null || true)
DB_STRUCTURE=$(echo "$DB_STRUCTURE" | tr -d '[:space:]')

if [ -z "$DB_STRUCTURE" ] || ! [[ "$DB_STRUCTURE" =~ ^[01]$ ]]; then
    echo "Invalid DB structure value: '$DB_STRUCTURE', skipping"
    exit 0
fi

if [ "$DB_STRUCTURE" = "1" ]; then
    echo "PASS: Critical database structure intact (keyring/, config.json, RocksDB metadata)"
    DETAILS=$(jq -cn '{status: "all_present", checks: ["keyring_dir", "config_json", "rocksdb_metadata"]}')
    sdk_always true "${ASSERTION_NAME}" "$DETAILS"
else
    echo "FAIL: Critical database structure missing components"
    DETAILS=$(jq -cn '{status: "missing_components", checks: ["keyring_dir", "config_json", "rocksdb_metadata"]}')
    sdk_always false "${ASSERTION_NAME}" "$DETAILS"
fi

exit 0
