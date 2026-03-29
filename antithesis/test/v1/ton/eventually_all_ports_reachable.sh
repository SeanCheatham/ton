#!/bin/bash
set -euo pipefail

# eventually_* driver: runs after Antithesis stops injecting faults.
# Checks that all 3 validator ports converge to reachable state.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/helper_sdk.sh"

VALIDATOR_HOST="${VALIDATOR_HOST:-ton-validator}"

udp_up=false
console_up=false
lite_up=false

nc -z -w 2 -u "${VALIDATOR_HOST}" 30001 2>/dev/null && udp_up=true
nc -z -w 2 "${VALIDATOR_HOST}" 30002 2>/dev/null && console_up=true
nc -z -w 2 "${VALIDATOR_HOST}" 30003 2>/dev/null && lite_up=true

if [[ "$udp_up" == "true" && "$console_up" == "true" && "$lite_up" == "true" ]]; then
    sdk_sometimes true "All ports reachable after faults settle" \
        "{\"udp_30001\":true,\"tcp_30002\":true,\"tcp_30003\":true}"
    echo "All ports reachable after faults settled"

    # Attempt an actual lite-client query to confirm functional liteserver recovery,
    # not just TCP connectivity. Skip if prerequisites are missing.
    LITE_QUERY_ASSERTION="Liteserver serves queries after faults settle"
    if ! command -v lite-client >/dev/null 2>&1; then
        echo "lite-client binary not found — skipping functional query check"
    elif [ ! -f /shared/liteserver.config.json ]; then
        echo "Liteserver config not available — skipping functional query check"
    else
        # Resolve hostname to IP (lite-client expects IP:port, not hostname:port)
        VALIDATOR_IP=""
        if command -v getent >/dev/null 2>&1; then
            VALIDATOR_IP=$(getent hosts "${VALIDATOR_HOST}" 2>/dev/null | awk '{print $1; exit}')
        fi
        if [ -z "$VALIDATOR_IP" ]; then
            VALIDATOR_IP=$(grep -m1 "${VALIDATOR_HOST}" /etc/hosts 2>/dev/null | awk '{print $1; exit}')
        fi
        if [ -z "$VALIDATOR_IP" ]; then
            VALIDATOR_IP="${VALIDATOR_HOST}"
        fi

        echo "Attempting lite-client query at ${VALIDATOR_IP}:30003 ..."
        LITE_OUT=""
        LITE_EXIT=0
        LITE_OUT=$(timeout 10 lite-client \
            -v 1 \
            -a "${VALIDATOR_IP}:30003" \
            -C /shared/liteserver.config.json \
            -c 'last' \
            -c 'quit' 2>&1) || LITE_EXIT=$?

        echo "lite-client output (first 300 chars): ${LITE_OUT:0:300}"

        # Parse a seqno from "latest masterchain block known to server is (...,<seqno>:...)"
        # The blockid format is (-1,8000000000000000,<seqno>:<hash>)
        SEQNO=""
        if echo "$LITE_OUT" | grep -qiE 'latest masterchain block'; then
            SEQNO=$(echo "$LITE_OUT" | grep -iE 'latest masterchain block' \
                | grep -oE ',([0-9]+):' | grep -oE '[0-9]+' | head -1)
        fi

        if [[ "$SEQNO" =~ ^[0-9]+$ && "$SEQNO" -gt 0 ]]; then
            DETAILS=$(jq -cn \
                --arg ip "$VALIDATOR_IP" \
                --argjson seqno "$SEQNO" \
                '{resolved_ip: $ip, seqno: $seqno}')
            echo "PASS: liteserver returned seqno=${SEQNO} — functionally recovered"
            sdk_sometimes true "$LITE_QUERY_ASSERTION" "$DETAILS"
        else
            echo "lite-client query did not return a parseable seqno (exit=${LITE_EXIT}) — not emitting assertion"
        fi
    fi
else
    echo "Not all ports reachable yet: UDP=$udp_up Console=$console_up Lite=$lite_up"
fi

exit 0
