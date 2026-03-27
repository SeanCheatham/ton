#!/usr/bin/env bash
set -euo pipefail

# Parallel driver: Validator has no IP-level input errors when healthy
# Reads /shared/validator_ip_errors (InHdrErrors + InAddrErrors from /proc/1/net/snmp)
# written by validator entrypoint heartbeat loop and asserts the count is zero when
# the validator is healthy. Non-zero counts indicate malformed or misrouted IP packets.

source "$(dirname "$0")/helper_sdk.sh"

VALIDATOR_HOST="${VALIDATOR_HOST:-ton-validator}"

if [ ! -f /shared/validator_ip_errors ]; then
    echo "IP errors file not present yet, skipping"
    sleep 10
    exit 0
fi

IP_ERRORS=$(cat /shared/validator_ip_errors 2>/dev/null || echo "-1")

if [ "$IP_ERRORS" = "-1" ]; then
    echo "IP errors data unavailable, skipping"
    sleep 10
    exit 0
fi

if ! [[ "$IP_ERRORS" =~ ^[0-9]+$ ]]; then
    echo "Invalid IP errors value: $IP_ERRORS, skipping"
    sleep 10
    exit 0
fi

# Check if all 3 ports are reachable
udp_up=false
console_up=false
lite_up=false
nc -z -w 1 -u "${VALIDATOR_HOST}" 30001 2>/dev/null && udp_up=true
nc -z -w 1 "${VALIDATOR_HOST}" 30002 2>/dev/null && console_up=true
nc -z -w 1 "${VALIDATOR_HOST}" 30003 2>/dev/null && lite_up=true

if [[ "$udp_up" != "true" || "$console_up" != "true" || "$lite_up" != "true" ]]; then
    echo "Validator not fully healthy, skipping assertion"
    sleep 10
    exit 0
fi

if [ "$IP_ERRORS" -gt 0 ]; then
    DETAILS=$(jq -cn --argjson errors "$IP_ERRORS" '{ip_input_errors: $errors}')
    sdk_always false "Validator has no IP-level input errors when healthy" "$DETAILS"
else
    sdk_always true "Validator has no IP-level input errors when healthy" '{"ip_input_errors":0}'
fi

sleep 10
exit 0
