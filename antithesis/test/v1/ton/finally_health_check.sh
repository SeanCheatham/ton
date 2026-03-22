#!/usr/bin/env bash
set -euo pipefail

# Final health check: verify the validator has recovered to a fully healthy state.
# Checks all three ports (UDP:30001, TCP:30002, TCP:30003) and emits a
# "sometimes" SDK assertion. If the validator recovered from fault injection,
# all ports will be reachable and the assertion fires with condition=true.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/helper_sdk.sh"

VALIDATOR_HOST="${VALIDATOR_HOST:-validator}"
ASSERTION_NAME="Validator recovers fully after fault injection"

echo "Running final health check..."

udp_up=false
console_up=false
lite_up=false

nc -z -u -w 2 "${VALIDATOR_HOST}" 30001 2>/dev/null && udp_up=true
nc -z -w 2 "${VALIDATOR_HOST}" 30002 2>/dev/null && console_up=true
nc -z -w 2 "${VALIDATOR_HOST}" 30003 2>/dev/null && lite_up=true

details=$(jq -cn \
  --argjson udp_30001 "$udp_up" \
  --argjson tcp_30002 "$console_up" \
  --argjson tcp_30003 "$lite_up" \
  '{"udp_30001": $udp_30001, "tcp_30002": $tcp_30002, "tcp_30003": $tcp_30003}')

if [[ "$udp_up" == "true" && "$console_up" == "true" && "$lite_up" == "true" ]]; then
    echo "PASS: all ports reachable — validator recovered fully"
    sdk_sometimes true "$ASSERTION_NAME" "$details"
    exit 0
else
    echo "FAIL: not all ports reachable — validator has not recovered"
    echo "  UDP:30001=${udp_up} TCP:30002=${console_up} TCP:30003=${lite_up}"
    sdk_sometimes false "$ASSERTION_NAME" "$details"
    exit 1
fi
