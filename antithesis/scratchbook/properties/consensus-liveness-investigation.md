# Consensus Liveness Investigation — 2026-03-27

## Summary

Investigation into consensus liveness failures observed in the Honey Whale 48h test run.

## C++ Assertions — Confirmed Correct

Catchain assertions are correctly placed and do not need changes:

| File | Line(s) | Type | Purpose |
|------|---------|------|---------|
| catchain/catchain-receiver.cpp | 69, 72 | REACHABLE | Catchain receiver initialization |
| catchain/catchain-receiver.cpp | 88, 117 | ALWAYS_OR_UNREACHABLE | Catchain receiver invariants |
| catchain/catchain-received-block.cpp | 128, 161 | REACHABLE | Block processing paths |
| catchain/catchain-received-block.cpp | 244, 248, 251, 254, 258 | ALWAYS_OR_UNREACHABLE | Block validation invariants |

## Restart Path Analysis

The entrypoint restart path is sound:
- Genesis sentinel persists on `/shared/genesis/.genesis_ready`
- Validator identity is correctly restored from `/shared/genesis/identity/${HOSTNAME}/`
- Phase A/B/C are properly skipped on restart via idempotency guards

## Root Cause: Liteserver Key Regenerated on Every Restart

**Bug:** Line 315 of `entrypoint-validator.sh` calls `generate-random-id -m id` unconditionally
inside the `if [ ! -f "${DB_ROOT}/config.json" ]` block. Since the local DB is ephemeral
(no volume mount), every container restart triggers this block, generating a **new** liteserver
key pair.

**Impact:**
1. `/shared/liteserver.config.json` is overwritten with a new public key
2. Any in-flight workload lite-client operations using the old key fail with auth errors
3. Race window where old config is still on disk while new key is being generated

**Fix applied:**
1. **Persist liteserver key** to `/shared/genesis/identity/${HOSTNAME}/liteserver_priv` and
   `liteserver_pub_b64` on first boot, restore from backup on restart (mirrors validator
   identity pattern)
2. **Atomic config write** — write to `.tmp` then `mv` to prevent partial reads
3. **Restart timing instrumentation** — log timestamps at key phases to diagnose future
   startup latency issues

## Expected Liveness Behavior

With 3 validators and BFT requiring 2/3 alive, aggressive fault injection (killing 2+ validators
simultaneously) can stall consensus indefinitely. This is expected BFT behavior, not a SUT bug.
The 128s downtime observed in the test run is likely Antithesis container kill/restart time.
