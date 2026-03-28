# Block Hash Consensus (Cross-Validator Fork Detection)

## Property

**Always:** "Cross-validator block hash matches at same height"
**Sometimes:** "Block hash verified across multiple validators"

## Type

- Always: Safety invariant (consensus fork detection)
- Sometimes: Liveness (cross-validator verification exercised)

## Why

Existing checks verify that validators have the same masterchain seqno (height),
but two validators could report the same height with *different block content* —
different root hashes and file hashes. This would be a consensus fork, the most
critical safety violation in a blockchain system.

This check compares the full block ID string `(-1,8000000000000000,N):ROOTHASH:FILEHASH`
across all responding validators at the same height.

## Coverage Gap

| Check | Existing | This |
|-------|----------|------|
| Same seqno across validators | parallel_driver_cross_validator_consistency | — |
| Height monotonicity | anytime_masterchain_height_monotonic | — |
| Same block hash at same height | — | **NEW** |

## Implementation

**File:** `antithesis/test/v1/ton/anytime_block_hash_consensus.sh`

**Driver type:** `anytime_*` — runs during active fault injection to catch forks under stress.

**Approach:**
1. Read last known masterchain seqno from `/shared/_last_mc_seqno`
2. Check seqno - 2 (gives propagation time, avoids false positives)
3. Query each validator with `byseqno -1 8000000000000000 <seqno>`
4. Parse full block ID from output
5. Compare across all responding validators

**byseqno syntax** (from lite-client.cpp:1082):
`byseqno <workchain> <shard-prefix> <seqno>` → `byseqno -1 8000000000000000 N`

**Output format** (from lite-client.cpp:3291):
`block header of (-1,8000000000000000,N):ROOTHASH:FILEHASH @ utime lt start..end`

**Block ID extraction:**
`grep -oE '\(-1,[0-9a-fA-F]+,[0-9]+\):[0-9A-Fa-f]+:[0-9A-Fa-f]+'`

## Skip Conditions (graceful, no false positives)

- `/shared/_last_mc_seqno` missing or value < 3
- lite-client binary unavailable
- Fewer than 2 validators responding
- Liteserver configs missing for responding validators

## Dependencies

- `anytime_masterchain_height_monotonic.sh` writes `/shared/_last_mc_seqno`
- Liteserver configs at `/shared/liteserver{,2,3}.config.json`

## Assertions

| Name | Type | Trigger |
|------|------|---------|
| Cross-validator block hash matches at same height | Always | Any 2+ validators return different block IDs at same seqno |
| Block hash verified across multiple validators | Sometimes | 2+ validators respond with matching hashes |
