#!/usr/bin/env bash
set -euo pipefail

# Driver: At least 2 of 3 validators have a fresh heartbeat simultaneously.
# Simplex consensus requires a 2/3+ quorum to make progress. If fewer than 2
# validators are live (as measured by heartbeat freshness), the chain cannot
# produce blocks. This is an "always" property: at no point should quorum drop
# below 2 during normal (non-fault) operation.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/helper_sdk.sh"

ASSERTION_NAME="Consensus quorum: at least 2 of 3 validators have fresh heartbeats"

sdk_catalog_always "${ASSERTION_NAME}"

MAX_AGE=90
NOW=$(date +%s)

# Check heartbeat freshness for each validator. Validator 1 uses legacy path.
ALIVE=0
DETAILS_PARTS=""

for IDX in 1 2 3; do
    if [ "${IDX}" = "1" ]; then
        HB_FILE="/shared/validator_heartbeat"
    else
        HB_FILE="/shared/validator${IDX}_heartbeat"
    fi

    ALIVE_THIS=false
    if [ -f "${HB_FILE}" ]; then
        FILE_MTIME=$(stat -c %Y "${HB_FILE}" 2>/dev/null || echo 0)
        FILE_AGE=$(( NOW - FILE_MTIME ))
        if [ "${FILE_AGE}" -le "${MAX_AGE}" ]; then
            HB_TS=$(cat "${HB_FILE}" 2>/dev/null || true)
            HB_TS=$(echo "$HB_TS" | tr -d '[:space:]')
            if [[ "${HB_TS}" =~ ^[0-9]+$ ]]; then
                HB_AGE=$(( NOW - HB_TS ))
                if [ "${HB_AGE}" -le "${MAX_AGE}" ]; then
                    ALIVE_THIS=true
                    ALIVE=$(( ALIVE + 1 ))
                fi
            fi
        fi
    fi

    DETAILS_PARTS="${DETAILS_PARTS} \"validator${IDX}\": ${ALIVE_THIS},"
done

# Trim trailing comma
DETAILS_PARTS="${DETAILS_PARTS%,}"

echo "Validators with fresh heartbeats: ${ALIVE}/3"

if [ "${ALIVE}" -ge 2 ]; then
    echo "PASS: quorum is live (${ALIVE}/3 validators)"
    sdk_always true "${ASSERTION_NAME}" \
        "$(jq -cn --argjson alive "${ALIVE}" "{alive_count: \$alive, quorum_threshold: 2, ${DETAILS_PARTS}}")"
else
    echo "FAIL: quorum lost (${ALIVE}/3 validators have fresh heartbeats)"
    sdk_always false "${ASSERTION_NAME}" \
        "$(jq -cn --argjson alive "${ALIVE}" "{alive_count: \$alive, quorum_threshold: 2, ${DETAILS_PARTS}}")"
fi

exit 0
