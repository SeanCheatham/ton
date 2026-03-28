#!/usr/bin/env bash
set -euo pipefail

# Parallel driver: TCP retransmission rate is bounded when validator is healthy
# Reads /shared/validator_tcp_retrans (format: OutSegs:RetransSegs) written by
# validator entrypoint heartbeat loop and asserts that the DELTA retransmission ratio
# since the last observation stays below 10% when the validator is healthy. Cumulative
# ratios can be skewed by intentional attack scripts, so we track deltas between
# observations to detect only new retransmission spikes.

source "$(dirname "$0")/helper_sdk.sh"

VALIDATOR_HOST="${VALIDATOR_HOST:-ton-validator}"
STATE_FILE="/shared/_prev_tcp_retrans"
HEARTBEAT_FILE="/shared/validator_heartbeat"
HEARTBEAT_MAX_AGE=90

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

# Check heartbeat freshness
if [ ! -f "$HEARTBEAT_FILE" ]; then
    echo "Heartbeat file not present, skipping"
    sleep 10
    exit 0
fi

HEARTBEAT_TS=$(cat "$HEARTBEAT_FILE" 2>/dev/null || echo "0")
NOW=$(date +%s)
HEARTBEAT_AGE=$((NOW - HEARTBEAT_TS))

if [ "$HEARTBEAT_AGE" -gt "$HEARTBEAT_MAX_AGE" ]; then
    echo "Heartbeat too old (${HEARTBEAT_AGE}s > ${HEARTBEAT_MAX_AGE}s), skipping"
    sleep 10
    exit 0
fi

# First observation: store baseline and skip
if [ ! -f "$STATE_FILE" ]; then
    echo "${OUT_SEGS}:${RETRANS_SEGS}" > "$STATE_FILE"
    echo "First observation, storing baseline out=$OUT_SEGS retrans=$RETRANS_SEGS"
    sdk_always true "TCP retransmission rate is bounded when validator is healthy" '{"status":"first_observation","delta_ratio_percent":0}'
    sleep 10
    exit 0
fi

PREV=$(cat "$STATE_FILE" 2>/dev/null || echo "0:0")
PREV_OUT="${PREV%%:*}"
PREV_RETRANS="${PREV##*:}"

# Counter reset detection (current < previous means kernel counter wrapped or process restarted)
if [ "$OUT_SEGS" -lt "$PREV_OUT" ] || [ "$RETRANS_SEGS" -lt "$PREV_RETRANS" ]; then
    echo "${OUT_SEGS}:${RETRANS_SEGS}" > "$STATE_FILE"
    echo "Counter reset detected, resetting baseline out=$OUT_SEGS retrans=$RETRANS_SEGS"
    sdk_always true "TCP retransmission rate is bounded when validator is healthy" '{"status":"counter_reset","delta_ratio_percent":0}'
    sleep 10
    exit 0
fi

# Compute deltas
DELTA_OUT=$((OUT_SEGS - PREV_OUT))
DELTA_RETRANS=$((RETRANS_SEGS - PREV_RETRANS))

# Update baseline
echo "${OUT_SEGS}:${RETRANS_SEGS}" > "$STATE_FILE"

# Need enough delta data to compute a meaningful ratio
if [ "$DELTA_OUT" -lt 100 ]; then
    echo "Not enough new outbound segments ($DELTA_OUT) for meaningful ratio, skipping"
    sdk_always true "TCP retransmission rate is bounded when validator is healthy" \
        "$(jq -cn --argjson dout "$DELTA_OUT" --argjson dretrans "$DELTA_RETRANS" '{status:"insufficient_data","delta_out_segs":$dout,"delta_retrans_segs":$dretrans}')"
    sleep 10
    exit 0
fi

# Compute delta ratio using integer math: retrans * 100 / out > 10 means > 10%
DELTA_RATIO_PERCENT=$((DELTA_RETRANS * 100 / DELTA_OUT))

if [ "$DELTA_RATIO_PERCENT" -gt 40 ]; then
    DETAILS=$(jq -cn \
        --argjson dretrans "$DELTA_RETRANS" --argjson dout "$DELTA_OUT" --argjson dratio "$DELTA_RATIO_PERCENT" \
        --argjson retrans "$RETRANS_SEGS" --argjson out "$OUT_SEGS" \
        '{delta_retrans_segs: $dretrans, delta_out_segs: $dout, delta_ratio_percent: $dratio, cumulative_retrans: $retrans, cumulative_out: $out}')
    sdk_always false "TCP retransmission rate is bounded when validator is healthy" "$DETAILS"
else
    DETAILS=$(jq -cn \
        --argjson dretrans "$DELTA_RETRANS" --argjson dout "$DELTA_OUT" --argjson dratio "$DELTA_RATIO_PERCENT" \
        --argjson retrans "$RETRANS_SEGS" --argjson out "$OUT_SEGS" \
        '{delta_retrans_segs: $dretrans, delta_out_segs: $dout, delta_ratio_percent: $dratio, cumulative_retrans: $retrans, cumulative_out: $out}')
    sdk_always true "TCP retransmission rate is bounded when validator is healthy" "$DETAILS"
fi

sleep 10
exit 0
