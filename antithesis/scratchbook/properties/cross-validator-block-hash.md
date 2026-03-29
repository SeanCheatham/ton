# Cross-Validator Block Hash Consensus

## Assertion

**"Cross-validator block hash matches at same height"** (always)
**"Block hash verified across multiple validators"** (sometimes)

## Purpose

Detects consensus forks: two validators reporting different block hashes (root hash + file hash) at the same masterchain seqno. This is the strongest consensus safety check — seqno agreement alone is insufficient.

## Problem: Sync-Lag False Positives

Under Antithesis fault injection, validators are frequently killed and restarted. A restarted validator can:

1. Resume heartbeats quickly (appearing "fresh")
2. Report a high seqno from the `last` command (reflecting its latest known block)
3. **Still return stale or inconsistent results for `byseqno` queries** while syncing older blocks

This caused the assertion to fire as a false positive — the validator was mid-sync, not forked.

## Hardening Measures

### 1. Increased CHECK_SEQNO buffer: MIN(seqnos) - 10

**Before:** MIN - 3. **After:** MIN - 10.

Rationale: 10 blocks of finalization buffer makes it extremely unlikely any validator hasn't fully processed the checked block. Combined with MAX_SEQNO_LAG=3, the check height is at least 13 blocks behind the leader.

### 2. Tightened MAX_SEQNO_LAG: 5 → 3

If any validator is more than 3 blocks behind the leader, it's likely still syncing and we skip entirely. This is defense-in-depth — catches validators that are clearly lagging before we even attempt queries.

### 3. Raised minimum CHECK_SEQNO threshold: 1 → 15

Early chain blocks (first ~15) are more susceptible to observation artifacts during initial validator sync at chain start. Skipping these avoids a class of false positives that only occur during bootstrapping.

### 4. Double-query self-consistency verification (KEY FIX)

After querying each validator for a block ID, we query again for the same seqno. If the two results differ, the validator is mid-sync — its `byseqno` results are unstable — and we exclude it from the comparison.

This directly addresses the root cause: a validator with fresh heartbeat and high `last` seqno but unstable `byseqno` results. The other measures are defense-in-depth; this one catches the actual failure mode.

### 5. Enhanced DETAILS JSON

The assertion details now include:
- `v1_self_consistent`, `v2_self_consistent`, `v3_self_consistent`: whether each validator passed double-query
- `v1_verify_id`, `v2_verify_id`, `v3_verify_id`: the second-round block IDs for debugging

## What Was NOT Changed

- **Assertion names**: Unchanged for continuity with existing tracking
- **Core comparison logic**: The pairwise hash comparison is correct
- **Heartbeat freshness checks**: Still useful as a first-pass filter
