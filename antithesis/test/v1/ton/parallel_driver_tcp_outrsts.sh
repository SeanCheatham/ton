#!/usr/bin/env bash
set -euo pipefail

# Parallel driver: TCP reset rate is bounded when validator is healthy
# Reads /shared/validator_tcp_outrsts (format: InSegs:OutRsts) written by
# validator entrypoint heartbeat loop and asserts that the reset ratio
# stays below 50% when the validator is healthy. High reset rates indicate
# socket backlog overflow, internal handler errors, or resource exhaustion.

source "$(dirname "$0")/helper_sdk.sh"

VALIDATOR_HOST="${VALIDATOR_HOST:-ton-validator}"

if [ ! -f /shared/validator_tcp_outrsts ]; then
    echo "TCP outrsts file not present yet, skipping"
    sleep 10
    exit 0
fi

RAW=$(cat /shared/validator_tcp_outrsts 2>/dev/null || echo "-1:-1")

if [ "$RAW" = "-1:-1" ]; then
    echo "TCP outrsts data unavailable, skipping"
    sleep 10
    exit 0
fi

IN_SEGS="${RAW%%:*}"
OUT_RSTS="${RAW##*:}"

if ! [[ "$IN_SEGS" =~ ^[0-9]+$ ]] || ! [[ "$OUT_RSTS" =~ ^[0-9]+$ ]]; then
    echo "Invalid TCP outrsts values: $RAW, skipping"
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

# Need enough data to compute a meaningful ratio
if [ "$IN_SEGS" -lt 50 ]; then
    echo "Not enough inbound segments ($IN_SEGS) for meaningful ratio, skipping"
    sleep 10
    exit 0
fi

# Compute ratio using integer math: out_rsts * 100 / in_segs > 50 means > 50%
RATIO_PERCENT=$((OUT_RSTS * 100 / IN_SEGS))

if [ "$RATIO_PERCENT" -gt 50 ]; then
    DETAILS=$(jq -cn --argjson in_segs "$IN_SEGS" --argjson out_rsts "$OUT_RSTS" --argjson ratio "$RATIO_PERCENT" \
        '{in_segs: $in_segs, out_rsts: $out_rsts, ratio_percent: $ratio}')
    sdk_always false "Validator TCP reset rate is bounded when healthy" "$DETAILS"
else
    DETAILS=$(jq -cn --argjson in_segs "$IN_SEGS" --argjson out_rsts "$OUT_RSTS" --argjson ratio "$RATIO_PERCENT" \
        '{in_segs: $in_segs, out_rsts: $out_rsts, ratio_percent: $ratio}')
    sdk_always true "Validator TCP reset rate is bounded when healthy" "$DETAILS"
fi

sleep 10
exit 0
