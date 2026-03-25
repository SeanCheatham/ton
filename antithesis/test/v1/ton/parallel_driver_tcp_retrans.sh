#!/usr/bin/env bash
set -euo pipefail

# Parallel driver: TCP retransmission rate is bounded when validator is healthy
# Reads /shared/validator_tcp_retrans (format: OutSegs:RetransSegs) written by
# validator entrypoint heartbeat loop and asserts that the retransmission ratio
# stays below 10% when the validator is healthy. High retransmission rates indicate
# network congestion, packet loss, or TCP stack problems invisible to interface counters.

source "$(dirname "$0")/helper_sdk.sh"

VALIDATOR_HOST="${VALIDATOR_HOST:-validator}"

if [ ! -f /shared/validator_tcp_retrans ]; then
    echo "TCP retrans file not present yet, skipping"
    sleep 10
    exit 0
fi

RAW=$(cat /shared/validator_tcp_retrans 2>/dev/null || echo "-1:-1")

if [ "$RAW" = "-1:-1" ]; then
    echo "TCP retrans data unavailable, skipping"
    sleep 10
    exit 0
fi

OUT_SEGS="${RAW%%:*}"
RETRANS_SEGS="${RAW##*:}"

if ! [[ "$OUT_SEGS" =~ ^[0-9]+$ ]] || ! [[ "$RETRANS_SEGS" =~ ^[0-9]+$ ]]; then
    echo "Invalid TCP retrans values: $RAW, skipping"
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
if [ "$OUT_SEGS" -lt 100 ]; then
    echo "Not enough outbound segments ($OUT_SEGS) for meaningful ratio, skipping"
    sleep 10
    exit 0
fi

# Compute ratio using integer math: retrans * 100 / out > 10 means > 10%
RATIO_PERCENT=$((RETRANS_SEGS * 100 / OUT_SEGS))

if [ "$RATIO_PERCENT" -gt 10 ]; then
    DETAILS=$(jq -cn --argjson retrans "$RETRANS_SEGS" --argjson out "$OUT_SEGS" --argjson ratio "$RATIO_PERCENT" \
        '{retrans_segs: $retrans, out_segs: $out, ratio_percent: $ratio}')
    sdk_always false "TCP retransmission rate is bounded when validator is healthy" "$DETAILS"
else
    DETAILS=$(jq -cn --argjson retrans "$RETRANS_SEGS" --argjson out "$OUT_SEGS" --argjson ratio "$RATIO_PERCENT" \
        '{retrans_segs: $retrans, out_segs: $out, ratio_percent: $ratio}')
    sdk_always true "TCP retransmission rate is bounded when validator is healthy" "$DETAILS"
fi

sleep 10
exit 0
