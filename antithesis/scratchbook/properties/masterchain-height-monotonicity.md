# Masterchain Height Monotonicity

## Property

**Masterchain block height is monotonically non-decreasing.**

Once a liteserver has served masterchain block at seqno N, it must never subsequently serve a block at seqno < N. A violation indicates a consensus rollback — one of the most critical safety bugs possible in a blockchain.

## Assertion Details

| Field | Value |
|-------|-------|
| Type | Always (safety invariant) |
| Name | `Masterchain block height is monotonically non-decreasing` |
| Driver | `anytime_masterchain_height_monotonic.sh` |
| Phase | anytime (runs during active fault injection) |
| State file | `/shared/_last_mc_seqno` |

### Secondary Assertion

| Field | Value |
|-------|-------|
| Type | Sometimes (liveness/progress) |
| Name | `Masterchain height observed advancing during faults` |
| Trigger | Height advanced AND heartbeat is stale (>30s) or missing |

## Mechanism

1. Query masterchain seqno via `lite-client -c "last"` on primary validator
2. Compare against previously observed seqno stored in `/shared/_last_mc_seqno`
3. If current < previous: emit `sdk_always false` — consensus rollback detected
4. If current >= previous: emit `sdk_always true`, update state file
5. If current > previous AND heartbeat stale: emit `sdk_sometimes true` for fault+progress

## Skip Conditions (no assertion emitted)

- `lite-client` binary not available
- `/shared/liteserver.config.json` not present
- Liteserver port not reachable (`nc -z -w 2`)
- lite-client query fails or returns unparseable output
- First observation (no previous seqno to compare against)

These skips prevent false positives during validator downtime caused by fault injection.

## Why This Matters

A masterchain seqno rollback would mean:
- A validator is serving blocks from a forked/abandoned chain
- Consensus failed to prevent conflicting block production
- Client-visible state could become inconsistent

This is the most fundamental safety property of any blockchain consensus protocol.

## Coverage Gap Addressed

Prior to this script, all `anytime_*` drivers checked infrastructure metrics only (heartbeat validity, reachability, quorum). This is the first `anytime_` driver that checks a **blockchain data invariant** during fault injection.
