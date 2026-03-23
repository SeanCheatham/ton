#!/usr/bin/env bash
set -euo pipefail

# Driver workload: detect validator recovery transitions during active fault injection.
# Tracks the validator's previous health state via /shared/validator_prev_state.
# When a down→up transition is observed (all three ports become reachable after
# previously being down), OR when the heartbeat resumes freshness after being stale,
# this emits a "sometimes" assertion with condition=true.
# The "sometimes" semantic requires this to happen at least once during the test run,
# proving the validator can recover while faults are actively being injected.
#
# Heartbeat-gap detection: The heartbeat is written to a Docker volume (not network-
# dependent), making it a more reliable indicator of process health than port checks
# which can appear down due to network partitions between containers.
# Runs repeatedly in parallel during fault injection.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/helper_sdk.sh"

VALIDATOR_HOST="${VALIDATOR_HOST:-validator}"
UDP_PORT="${VALIDATOR_PORT:-30001}"
CONSOLE_PORT="${CONSOLE_PORT:-30002}"
LITE_PORT="${LITE_PORT:-30003}"

ASSERTION_NAME="Validator recovers mid-test after going down"
STATE_FILE="/shared/validator_prev_state"
HEARTBEAT_STATE_FILE="/shared/validator_heartbeat_prev_fresh"

# Catalog the assertion on first invocation
sdk_catalog_sometimes "$ASSERTION_NAME"

echo "Checking validator recovery state..."

# --- Method 1: Port-based detection (original) ---
udp_ok=false
console_ok=false
lite_ok=false

nc -z -u -w 2 "${VALIDATOR_HOST}" "${UDP_PORT}" 2>/dev/null && udp_ok=true
nc -z -w 2 "${VALIDATOR_HOST}" "${CONSOLE_PORT}" 2>/dev/null && console_ok=true
nc -z -w 2 "${VALIDATOR_HOST}" "${LITE_PORT}" 2>/dev/null && lite_ok=true

# Determine current port state
if [[ "$udp_ok" == "true" && "$console_ok" == "true" && "$lite_ok" == "true" ]]; then
    port_state="up"
else
    port_state="down"
fi

echo "  UDP:${UDP_PORT}=${udp_ok} TCP:${CONSOLE_PORT}=${console_ok} TCP:${LITE_PORT}=${lite_ok} => ${port_state}"

# Read previous port state (default: "unknown" on first run)
if [[ -f "$STATE_FILE" ]]; then
    prev_port_state=$(cat "$STATE_FILE")
else
    prev_port_state="unknown"
fi

# Port-based recovery: down → up
port_recovery=false
if [[ "$prev_port_state" == "down" && "$port_state" == "up" ]]; then
    port_recovery=true
    echo "PORT RECOVERY DETECTED: validator ports transitioned from down to up"
fi

# Persist current port state for next invocation
echo -n "$port_state" > "$STATE_FILE"

# --- Method 2: Heartbeat-gap detection ---
# If /shared/validator_heartbeat goes stale (>30s) then refreshes (<15s),
# that's a recovery — independent of port reachability.
heartbeat_recovery=false
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

# Read previous heartbeat freshness state
if [[ -f "$HEARTBEAT_STATE_FILE" ]]; then
    prev_hb_fresh=$(cat "$HEARTBEAT_STATE_FILE")
else
    prev_hb_fresh="unknown"
fi

# Current heartbeat freshness
if [ "$HB_AGE" -le 15 ]; then
    current_hb_fresh="fresh"
elif [ "$HB_AGE" -gt 30 ]; then
    current_hb_fresh="stale"
else
    # Between 15-30s: keep previous state to avoid flapping
    current_hb_fresh="$prev_hb_fresh"
fi

echo "  Heartbeat age: ${HB_AGE}s, prev_fresh: ${prev_hb_fresh}, current_fresh: ${current_hb_fresh}"

# Heartbeat-based recovery: stale → fresh
if [[ "$prev_hb_fresh" == "stale" && "$current_hb_fresh" == "fresh" ]]; then
    heartbeat_recovery=true
    echo "HEARTBEAT RECOVERY DETECTED: heartbeat transitioned from stale to fresh"
fi

# Persist current heartbeat freshness state
echo -n "$current_hb_fresh" > "$HEARTBEAT_STATE_FILE"

# --- Emit assertion ---
timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

details=$(jq -cn \
    --arg prev_port "$prev_port_state" \
    --arg curr_port "$port_state" \
    --arg prev_hb "$prev_hb_fresh" \
    --arg curr_hb "$current_hb_fresh" \
    --argjson hb_age "$HB_AGE" \
    --argjson port_recovery "$port_recovery" \
    --argjson hb_recovery "$heartbeat_recovery" \
    --arg ts "$timestamp" \
    --argjson udp "$udp_ok" \
    --argjson console "$console_ok" \
    --argjson lite "$lite_ok" \
    '{prev_port_state: $prev_port, current_port_state: $curr_port, prev_heartbeat: $prev_hb, current_heartbeat: $curr_hb, heartbeat_age_s: $hb_age, port_recovery: $port_recovery, heartbeat_recovery: $hb_recovery, timestamp: $ts, udp_30001: $udp, tcp_30002: $console, tcp_30003: $lite}')

# Recovery detected via either method
if [[ "$port_recovery" == "true" || "$heartbeat_recovery" == "true" ]]; then
    echo "RECOVERY DETECTED via port=${port_recovery} heartbeat=${heartbeat_recovery}"
    sdk_sometimes true "$ASSERTION_NAME" "$details"
else
    if [[ "$port_state" == "down" || "$current_hb_fresh" == "stale" ]]; then
        echo "Validator is down/stale — no recovery transition yet"
    elif [[ "$prev_port_state" == "unknown" && "$prev_hb_fresh" == "unknown" ]]; then
        echo "First invocation — establishing baseline state"
    else
        echo "No state transition (ports: ${prev_port_state}->${port_state}, hb: ${prev_hb_fresh}->${current_hb_fresh})"
    fi
    sdk_sometimes false "$ASSERTION_NAME" "$details"
fi

# Always exit 0 so Test Composer keeps re-scheduling this driver
exit 0
