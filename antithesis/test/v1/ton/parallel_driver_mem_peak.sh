#!/usr/bin/env bash
source /opt/antithesis/test/v1/ton/helper_sdk.sh
VALIDATOR_HOST="${VALIDATOR_HOST:-ton-validator}"
PROPERTY="Validator peak memory (VmPeak) is bounded"
PEAK_LIMIT=4194304  # 4GB in KB

# Only check when healthy (all 3 ports up)
udp_up=false; console_up=false; lite_up=false
nc -z -w 1 -u "$VALIDATOR_HOST" 30001 2>/dev/null && udp_up=true
nc -z -w 1 "$VALIDATOR_HOST" 30002 2>/dev/null && console_up=true
nc -z -w 1 "$VALIDATOR_HOST" 30003 2>/dev/null && lite_up=true

if [[ "$udp_up" != "true" || "$console_up" != "true" || "$lite_up" != "true" ]]; then
    echo "Validator not fully healthy, skipping VmPeak check"
    exit 0
fi

PEAK_KB=$(cat /shared/validator_mem_peak 2>/dev/null || echo "")
if [[ -z "$PEAK_KB" ]]; then
    echo "VmPeak file not present yet, skipping"
    exit 0
fi

if ! [[ "$PEAK_KB" =~ ^[0-9]+$ ]]; then
    echo "Invalid VmPeak value: $PEAK_KB, skipping"
    exit 0
fi

if [ "$PEAK_KB" -le 0 ]; then
    echo "VmPeak is 0 or negative, skipping"
    exit 0
fi

if [ "$PEAK_KB" -lt "$PEAK_LIMIT" ]; then
    sdk_always true "$PROPERTY" "$(jq -cn --argjson peak "$PEAK_KB" --argjson limit "$PEAK_LIMIT" '{peak_kb: $peak, peak_mb: ($peak / 1024 | floor), limit_kb: $limit, limit_mb: ($limit / 1024 | floor)}')"
else
    sdk_always false "$PROPERTY" "$(jq -cn --argjson peak "$PEAK_KB" --argjson limit "$PEAK_LIMIT" '{peak_kb: $peak, peak_mb: ($peak / 1024 | floor), limit_kb: $limit, limit_mb: ($limit / 1024 | floor)}')"
fi
