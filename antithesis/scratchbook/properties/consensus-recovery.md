# Consensus Recovery After Fault

## Property
**Name:** `Consensus recovered after fault`
**Type:** Sometimes (liveness)
**File:** `antithesis/test/v1/ton/eventually_consensus_recovers.sh`
**Phase:** `eventually_*` (runs with faults paused)

## Motivation

Existing recovery detection (`parallel_driver_recovery_observed.sh`) operates at the PORT level — it detects when network ports transition from unreachable to reachable. However, a validator can have all ports up while consensus is stalled (no new blocks being produced). This property checks DATA-level recovery: block production actually resumes after a detected fault.

## Mechanism

Two-phase state machine persisted in `/shared/_consensus_recovery_state`:

### Cold-Start Guard
On the very first invocation (no `last_good_seqno` and no `fault_ts` in the state file), the script skips fault detection and assertion emission entirely. This prevents a false fault on cold start when `query_ok=false` simply because no healthy baseline has been established yet. The script logs the situation and exits 0 without polluting Sometimes assertions.

### Phase 1 — Fault Detection
A fault is recorded when **all** of the following hold:
- Either liteserver query fails or heartbeat is stale (>60s old)
- A healthy baseline exists (`last_good_seqno` was previously recorded)

On fault detection, we persist `fault_ts` and `last_good_seqno` (the last successfully queried seqno before the fault).

### Phase 2 — Recovery Detection
Recovery is confirmed when:
- A fault was previously recorded (`fault_ts` exists in state file)
- Liteserver now responds successfully
- Current seqno > `last_good_seqno` (blocks advanced past the pre-fault point)

On recovery, we emit `sdk_sometimes true "Consensus recovered after fault"` and clear the fault state to allow detecting additional fault/recovery cycles.

## Relationship to Other Assertions

| Assertion | Level | What it checks |
|-----------|-------|----------------|
| `parallel_driver_recovery_observed.sh` | Port | Network ports transition down→up |
| `eventually_block_height_advances.sh` | Data | Blocks advance (no fault context) |
| **`eventually_consensus_recovers.sh`** | **Data + Fault** | **Blocks advance AFTER a detected fault** |

## Why `eventually_*`

The `eventually_*` phase runs after faults are paused. This is the ideal time to check recovery because:
1. Faults have already been injected (creating the fault detection opportunity during parallel/anytime phases via state file persistence)
2. The system should now be recovering — if it can't produce blocks with faults paused, that's a real problem

## Antithesis Value

The `sometimes` assertion acts as a deterministic checkpoint for Antithesis's exploration. It tells the fuzzer: "branch from moments where faults are detected" — amplifying the probability of finding bugs in recovery paths, consensus re-establishment, and state synchronization after interruption.
