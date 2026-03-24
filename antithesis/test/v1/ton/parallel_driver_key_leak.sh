#!/usr/bin/env bash

# Parallel driver: Validator log does not contain private key material
# Scans validator logs (excluding startup config dump) and shared metric files
# for private key material patterns (pk.ed25519). The validator generates
# Ed25519 private keys during initialization — these must NEVER leak into
# runtime log output or shared metric files.

source "$(dirname "$0")/helper_sdk.sh"

ASSERTION_NAME="Validator log does not contain private key material"
LOG_FILE="/shared/validator.log"

# Precondition: log file must exist
if [ ! -f "$LOG_FILE" ]; then
    echo "Log file not present yet, skipping"
    sdk_always true "$ASSERTION_NAME" '{"status":"log_not_present"}'
    exit 0
fi

LOG_LINES=$(wc -l < "$LOG_FILE" 2>/dev/null || echo "0")
if [ "$LOG_LINES" -lt 21 ]; then
    echo "Log file too short (${LOG_LINES} lines), skipping"
    sdk_always true "$ASSERTION_NAME" "$(jq -cn --argjson lines "$LOG_LINES" '{status:"log_too_short", lines: $lines}')"
    exit 0
fi

LEAKED=false
LEAK_DETAIL=""

# Check 1: Scan log file (excluding first 20 lines of startup config dump) for private key patterns
# pk.ed25519 is the TL type tag for Ed25519 private keys in TON's serialization format
LOG_HITS=$(tail -n +"21" "$LOG_FILE" 2>/dev/null | grep -ciE 'pk\.ed25519' 2>/dev/null || echo "0")

if [ "$LOG_HITS" -gt 0 ]; then
    LEAKED=true
    SAMPLE=$(tail -n +"21" "$LOG_FILE" 2>/dev/null | grep -iE 'pk\.ed25519' 2>/dev/null | head -3 | head -c 500 || true)
    LEAK_DETAIL="log_pk_ed25519_hits(${LOG_HITS})"
fi

# Check 2: Scan shared metric files for private key patterns
SHARED_HITS=0
for f in /shared/*; do
    [ -f "$f" ] || continue
    # Skip the log file itself (already checked above) and binary files
    [ "$f" = "$LOG_FILE" ] && continue
    HITS=$(grep -ciE 'pk\.ed25519' "$f" 2>/dev/null || echo "0")
    SHARED_HITS=$((SHARED_HITS + HITS))
done

if [ "$SHARED_HITS" -gt 0 ]; then
    LEAKED=true
    LEAK_DETAIL="${LEAK_DETAIL:+${LEAK_DETAIL},}shared_files_pk_hits(${SHARED_HITS})"
fi

DETAILS=$(jq -cn \
    --argjson log_hits "$LOG_HITS" \
    --argjson shared_hits "$SHARED_HITS" \
    --argjson leaked "$LEAKED" \
    --arg detail "${LEAK_DETAIL:-clean}" \
    '{log_pk_hits: $log_hits, shared_pk_hits: $shared_hits, leaked: $leaked, detail: $detail}')

if [ "$LEAKED" = "true" ]; then
    echo "FAIL: Private key material detected in logs/shared files: $LEAK_DETAIL"
    sdk_always false "$ASSERTION_NAME" "$DETAILS"
else
    echo "PASS: No private key material found in logs or shared files"
    sdk_always true "$ASSERTION_NAME" "$DETAILS"
fi

exit 0
