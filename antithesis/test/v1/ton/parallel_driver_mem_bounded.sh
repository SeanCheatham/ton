#!/usr/bin/env bash
set -euo pipefail

# Parallel driver: Validator memory usage is bounded
# Reads /shared/validator_mem_rss (written by validator entrypoint heartbeat loop)
# and asserts RSS stays below 2GB (2097152 KB). Catches memory leaks from
# interrupted operations, partial state rebuilds, and retried connections
# that accumulate under sustained fault injection.

source "$(dirname "$0")/helper_sdk.sh"

RSS_LIMIT=2097152  # 2GB in KB

if [ ! -f /shared/validator_mem_rss ]; then
    echo "RSS file not present yet, skipping"
    sleep 10
    exit 0
fi

RSS_KB=$(cat /shared/validator_mem_rss 2>/dev/null || echo "0")

# Validate we got a numeric value
if ! [[ "$RSS_KB" =~ ^[0-9]+$ ]]; then
    echo "Invalid RSS value: $RSS_KB, skipping"
    sleep 10
    exit 0
fi

if [ "$RSS_KB" -gt 0 ] && [ "$RSS_KB" -lt "$RSS_LIMIT" ]; then
    DETAILS=$(jq -cn --argjson rss "$RSS_KB" --argjson limit "$RSS_LIMIT" \
        '{rss_kb: $rss, rss_mb: ($rss / 1024 | floor), limit_kb: $limit}')
    sdk_always true "Validator memory usage is bounded" "$DETAILS"
elif [ "$RSS_KB" -ge "$RSS_LIMIT" ]; then
    DETAILS=$(jq -cn --argjson rss "$RSS_KB" --argjson limit "$RSS_LIMIT" \
        '{rss_kb: $rss, rss_mb: ($rss / 1024 | floor), limit_kb: $limit}')
    sdk_always false "Validator memory usage is bounded" "$DETAILS"
fi

sleep 10
exit 0
