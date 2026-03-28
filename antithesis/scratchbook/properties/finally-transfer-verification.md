# Finally: Transfer Data Verification

## Property

**All acknowledged transfers persist in final state**

At the end of an Antithesis timeline (after all faults have settled), every wallet seqno that was confirmed by `serial_driver_send_transfer.sh` must still be reflected in the blockchain state. If `last_confirmed_seqno = N`, then querying the wallet's seqno via `runmethod 85143` must return `>= N` on every reachable validator.

## Type

- **Always**: "All acknowledged transfers persist in final state" — safety invariant; violation means confirmed data was lost
- **Sometimes**: "Transfer state verified at end of timeline" — liveness; confirms the check actually ran and passed at least once

## Rationale

The existing `finally_health_check.sh` only checks port reachability. This script is the definitive data-loss detector: Antithesis injects faults throughout the timeline, and this is the verdict — did any confirmed transaction disappear?

## Mechanism

1. Read `/shared/tx/last_confirmed_seqno` (written by `serial_driver_send_transfer.sh` after each confirmed transfer)
2. Query wallet seqno from primary validator via `lite-client -c "runmethod <wallet> 85143"`
3. Assert `current_seqno >= last_confirmed_seqno` — if not, a confirmed transaction was lost
4. Repeat for validator2 and validator3 if reachable — all must agree
5. Report cross-validator agreement on final seqno

## Preconditions (skip gracefully)

- `lite-client` binary available
- Primary liteserver reachable on port 30003
- Liteserver config exists
- `last_confirmed_seqno` file exists with value > 0

## File

`antithesis/test/v1/ton/finally_verify_transfers.sh`

## Dependencies

- `serial_driver_send_transfer.sh` — writes `/shared/tx/last_confirmed_seqno` and `/shared/tx/last_confirmed_balance`
- Wallet address: `-1:0000000000000000000000000000000000000000000000000000000000000000`
- Runmethod 85143 (seqno getter)
