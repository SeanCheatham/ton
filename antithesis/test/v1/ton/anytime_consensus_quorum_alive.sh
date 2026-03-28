#!/usr/bin/env bash
set -euo pipefail

# Driver: At least 2 of 3 validators have a fresh heartbeat simultaneously.
# Simplex consensus requires a 2/3+ quorum to make progress. This is a
# "sometimes" property: during fault injection quorum loss is expected, but
# quorum should be present at least some of the time (branching checkpoint).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/helper_sdk.sh"

ASSERTION_NAME="Consensus quorum: at least 2 of 3 validators have fresh heartbeats"

sdk_catalog_sometimes "${ASSERTION_NAME}"

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
    sdk_sometimes true "${ASSERTION_NAME}" \
        "$(jq -cn --argjson alive "${ALIVE}" "{alive_count: \$alive, quorum_threshold: 2, ${DETAILS_PARTS}}")"
else
    echo "WARN: quorum lost (${ALIVE}/3 validators have fresh heartbeats) — expected during faults"
fi

exit 0
