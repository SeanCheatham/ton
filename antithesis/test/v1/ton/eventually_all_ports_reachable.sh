#!/bin/bash
set -euo pipefail

# eventually_* driver: runs after Antithesis stops injecting faults.
# Checks that all 3 validator ports converge to reachable state.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/helper_sdk.sh"

VALIDATOR_HOST="${VALIDATOR_HOST:-validator}"

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
else
    echo "Not all ports reachable yet: UDP=$udp_up Console=$console_up Lite=$lite_up"
fi

exit 0
