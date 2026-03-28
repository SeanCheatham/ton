# Property Catalog: TON Blockchain Node

## In-Process C++ SDK Assertions (validator/invariants.hpp)

The Antithesis C++ SDK (`third-party/antithesis-sdk-cpp/`) is now linked to the `validator` and `ton_validator` libraries. In-process assertions are embedded in `validator/invariants.hpp`, which is called on every block accept, apply, and proof verification.

### REACHABLE Markers (4)
- "Post-apply invariant check reached"
- "Post-accept invariant check reached"
- "Post-check-proof invariant check reached"
- "Post-check-proof-link invariant check reached"

### ALWAYS Assertions (~25)

**Post-apply (8 assertions):**
- "Block state received after apply"
- "Block state root hash initialized after apply"
- "Block logical time initialized after apply"
- "Block unix time initialized after apply"
- "Block split-after initialized after apply"
- "Block proof initialized after apply for non-genesis"
- "Block marked processed after apply"
- "Block marked applied after apply"

**Post-accept (11 assertions):**
- "Block received after accept"
- "Block state received after accept"
- "Block state root hash initialized after accept"
- "Block merge-before initialized after accept"
- "Block split-after initialized after accept"
- "Block prev initialized after accept"
- "Block logical time initialized after accept"
- "Block unix time initialized after accept"
- "Masterchain block proof initialized after accept"
- "Masterchain block applied after accept"
- "Masterchain key block flag initialized after accept"
- "Non-masterchain block proof link initialized after accept"

**Post-check-proof (8 assertions):**
- "Block merge-before initialized after proof check"
- "Block split-after initialized after proof check"
- "Block prev initialized after proof check"
- "Block state root hash initialized after proof check"
- "Block logical time initialized after proof check"
- "Block unix time initialized after proof check"
- "Block proof initialized after proof check"
- "Block key block flag initialized after proof check"

**Post-check-proof-link (7 assertions):**
- "Block merge-before initialized after proof link check"
- "Block split-after initialized after proof link check"
- "Block prev initialized after proof link check"
- "Block state root hash initialized after proof link check"
- "Block logical time initialized after proof link check"
- "Block unix time initialized after proof link check"
- "Block proof link initialized after proof link check"

### Build Integration
- `CMakeLists.txt`: `add_subdirectory(third-party/antithesis-sdk-cpp EXCLUDE_FROM_ALL)`
- `third-party/antithesis-sdk-cpp/CMakeLists.txt`: Added `target_include_directories(INTERFACE)`
- `validator/CMakeLists.txt`: Linked `antithesis-sdk-cpp` to `validator`
- `validator/impl/CMakeLists.txt`: Linked `antithesis-sdk-cpp` to `ton_validator`

These in-process assertions complement the external workload-based assertions (131 catalog entries in `entrypoint-workload.sh`).

## In-Process C++ SDK Assertions (validator/impl/validate-query.cpp)

Antithesis assertions are embedded inline in `validate-query.cpp` to cover the block validation pipeline — the core data integrity path where every block received from other validators is verified. These complement the block-processing assertions in `validator/invariants.hpp` and the liteserver API assertions.

### REACHABLE Markers (3)
- "Block validation query started" — confirms validation queries are being initiated via `start_up()`
- "Block validation completed successfully" — confirms validation queries finish successfully via `finish_query()`
- "Block validation rejected" — confirms rejection paths are exercised via `reject_query()` (critical signal during fault injection)

### ALWAYS Assertions (6)

**Hash Verification (3 assertions):**
- "Block candidate file hash matches declared hash" — file hash of block data matches the declared hash
- "Block candidate root hash matches declared hash" — root hash of deserialized block matches the declared hash
- "Previous state hash matches block header declaration" — previous state hash matches what the block header declares

**State Transition Integrity (3 assertions):**
- "Block state Merkle update is valid" — the Merkle update in the block is structurally valid
- "Computed next state hash matches block header declaration" — the computed next state hash matches the block header
- "New state generation time matches block header" — the new state's generation time is consistent with the block header

## In-Process C++ SDK Assertions (validator/impl/liteserver.cpp)

Antithesis assertions are embedded inline in `liteserver.cpp` to cover the liteserver API layer — the external query interface that lite-clients connect to. These complement the block-processing assertions in `validator/invariants.hpp`.

### REACHABLE Markers (3)
- "Liteserver query dispatched" — confirms liteserver queries are being dispatched via `perform()`
- "Liteserver query finished successfully" — confirms queries complete with a response via `finish_query()`
- "Liteserver query aborted" — confirms error/abort paths are exercised via `abort_query()`

### ALWAYS Assertions (6)
- "Liteserver response is non-empty" — every successful query response contains data
- "Block data is non-null in getBlock response" — block data fetched for getBlock is not null
- "Block state is non-null in getState response" — shard state fetched for getState is not null
- "Block data is non-null in getBlockHeader response" — block data fetched for getBlockHeader is not null
- "Block ID matches request in getBlockHeader response" — block ID in response matches the requested ID
- "Masterchain state is non-null for account query" — masterchain state is available when processing account queries

## In-Process C++ SDK Assertions (validator/impl/collator.cpp)

Antithesis assertions are embedded inline in `collator.cpp` to cover the block CONSTRUCTION pipeline — every block this validator proposes to the network is built here. This is the counterpart to `validate-query.cpp` (block validation). These assertions verify value flow conservation, hash integrity, structural validity, and size limits during block production.

### REACHABLE Markers (3)
- "Collator started" — confirms collation is being triggered via `start_up()`
- "Block candidate produced successfully" — confirms a block candidate was successfully produced and returned via `return_block_candidate()`
- "Collator fatal error" — confirms collation failure paths are exercised via `fatal_error()` (valuable during fault injection)

### ALWAYS Assertions (7)

**Value Flow & State Integrity (3 assertions):**
- "Collator value flow is balanced: in equals out" — the fundamental blockchain invariant: no value is created or destroyed
- "Collator Merkle update produces correct state hash" — the Merkle update applied to previous state produces the expected new state hash
- "Collator Merkle update generation succeeds" — Merkle update generation for the shard state completes successfully

**Structural Validation (2 assertions):**
- "Collator produced block passes structural validation" — the newly created block passes TL-B structural validation
- "Collator produced shard state passes structural validation" — the newly created shard state passes TL-B structural validation

**Size & Hash Consistency (2 assertions):**
- "Collator block size within consensus limit" — the serialized block size does not exceed the consensus-configured maximum
- "Collator previous block root hash is consistent" — the previous block's root hash matches the stored reference (zero state path)

---

## Bootstrap Properties

### 1. Validator Engine Startup Reachable

| | |
|---|---|
| **Type** | Reachability |
| **Property** | The validator-engine startup path is exercised |
| **Invariant** | `REACHABLE("validator engine startup reached")` in the validator-engine main initialization path |
| **Antithesis Angle** | Confirms the SUT boots successfully in the Antithesis environment |
| **Why It Matters** | Bootstrap verification — proves SDK integration works and the binary runs |

## Implemented Properties

### 2. Validator Subsystem Consistency: All Ports Reachable Together

| | |
|---|---|
| **Type** | Safety (Always) |
| **Property** | When the validator's main UDP port (30001) is reachable, the console TCP port (30002) and liteserver TCP port (30003) must also be reachable |
| **Invariant** | `ALWAYS(console_ok && lite_ok, "Validator subsystem consistency: all ports reachable together")` — evaluated only when UDP:30001 is up |
| **Antithesis Angle** | Fault injection may crash internal subsystems (ADNL, console, lite-server) while the main process stays alive |
| **Why It Matters** | Detects partial failures where the main process appears healthy but critical subsystems are down — a dangerous state for operators and clients |
| **Workload** | `parallel_driver_subsystem_consistency.sh` — runs repeatedly during fault injection |
| **Status** | ✅ Implemented |

### RocksDB LOG Contains No Write Stall Indicators When Validator Is Healthy

| | |
|---|---|
| **Type** | Safety (Always) |
| **Property** | When the validator is healthy (heartbeat fresh, all ports up), RocksDB LOG files contain no write stall patterns ("Stalling writes", "Stopping writes", "Write stall") |
| **Invariant** | `ALWAYS(write_stall_count == 0, "RocksDB LOG contains no write stall indicators when validator is healthy")` |
| **Antithesis Angle** | Fault injection may cause I/O delays that lead to compaction falling behind, triggering write stalls |
| **Why It Matters** | Write stalls indicate compaction cannot keep up with writes, causing cascading performance degradation and potential data loss |
| **Workload** | `parallel_driver_rocksdb_write_stalls.sh` — reads `/shared/validator_rocksdb_write_stalls` written by validator heartbeat loop |
| **Status** | ✅ Implemented |

### Validator Heartbeat Interval Is Regular When Healthy

| | |
|---|---|
| **Type** | Safety (Always) |
| **Property** | Consecutive heartbeat timestamps do not have gaps exceeding 30 seconds while the validator is healthy |
| **Invariant** | `ALWAYS(interval <= 30, "Validator heartbeat interval is regular when healthy")` |
| **Antithesis Angle** | Fault injection may cause CPU contention or I/O blocking that starves the heartbeat loop without killing the process |
| **Why It Matters** | Detects heartbeat loop starvation — different from freshness checks (absolute age) — this checks cadence regularity |
| **Workload** | `parallel_driver_heartbeat_regularity.sh` — tracks previous heartbeat timestamp in `/shared/validator_heartbeat_prev_check` |
| **Status** | ✅ Implemented |

### Validator Survives Empty UDP Packets

| | |
|---|---|
| **Type** | Safety (Always) |
| **Property** | The validator survives zero-length UDP datagrams sent to its ADNL port (30001) |
| **Invariant** | `ALWAYS(survived, "Validator survives empty UDP packets")` |
| **Antithesis Angle** | Zero-length packets can trigger off-by-one errors, null pointer dereferences, or division-by-zero in packet length calculations |
| **Why It Matters** | Tests the ADNL parser's base case — all other UDP tests send non-empty data (random, oversized, ADNL-structured) |
| **Workload** | `parallel_driver_empty_udp.sh` — sends 10 empty UDP datagrams then verifies all ports still reachable |
| **Status** | ✅ Implemented |

### TCP Retransmission Rate Is Bounded When Validator Is Healthy

| | |
|---|---|
| **Type** | Safety (Always) |
| **Property** | The ratio of TCP retransmitted segments (RetransSegs) to total outbound segments (OutSegs) stays below 10% when the validator is healthy |
| **Invariant** | `ALWAYS(retrans_segs * 100 / out_segs <= 10, "TCP retransmission rate is bounded when validator is healthy")` — evaluated only when all ports are up and OutSegs >= 100 |
| **Antithesis Angle** | Fault injection may cause network congestion or packet loss that triggers TCP retransmissions, invisible to interface-level error counters |
| **Why It Matters** | High retransmission rates degrade liteserver and console performance, cause latency spikes, and can cascade into timeout failures |
| **Workload** | `parallel_driver_tcp_retrans.sh` — reads `/shared/validator_tcp_retrans` (OutSegs:RetransSegs from `/proc/1/net/snmp`) |
| **Status** | ✅ Implemented |

### Validator Has No IP-Level Input Errors When Healthy

| | |
|---|---|
| **Type** | Safety (Always) |
| **Property** | The IP-level error counters (InHdrErrors + InAddrErrors) from `/proc/1/net/snmp` are zero when the validator is healthy |
| **Invariant** | `ALWAYS(ip_errors == 0, "Validator has no IP-level input errors when healthy")` — evaluated only when all ports are up |
| **Antithesis Angle** | Fault injection or adversarial traffic may produce malformed IP packets with corrupted headers |
| **Why It Matters** | Non-zero IP errors indicate network configuration problems or corrupted packet headers — relevant for adversarial resilience |
| **Workload** | `parallel_driver_ip_errors.sh` — reads `/shared/validator_ip_errors` (InHdrErrors + InAddrErrors from `/proc/1/net/snmp`) |
| **Status** | ✅ Implemented |

### Validator Has No UDP Buffer Errors When Healthy

| | |
|---|---|
| **Type** | Safety (Always) |
| **Property** | The UDP buffer error counters (RcvbufErrors and SndbufErrors) from `/proc/1/net/snmp` are both zero when the validator is healthy |
| **Invariant** | `ALWAYS(rcvbuf_errors == 0 && sndbuf_errors == 0, "Validator has no UDP buffer errors when healthy")` — evaluated only when all ports are up |
| **Antithesis Angle** | Fault injection may cause UDP buffer overflows leading to silent packet loss on the ADNL protocol |
| **Why It Matters** | UDP is the primary transport for TON's ADNL peer-to-peer protocol (port 30001). Buffer overflows cause silent packet loss — no application-level error is raised, and interface-level counters don't capture this. Silent UDP loss can cause missed blocks and consensus failures |
| **Workload** | `parallel_driver_udp_buf_errors.sh` — reads `/shared/validator_udp_buf_errors` (RcvbufErrors:SndbufErrors from `/proc/1/net/snmp`) |
| **Status** | ✅ Implemented |

### Validator Has No TCP Connection Failures When Healthy

| | |
|---|---|
| **Type** | Safety (Always) |
| **Property** | When the validator is healthy, TCP AttemptFails and EstabResets counters from /proc/net/snmp are both zero |
| **Invariant** | `ALWAYS(attempt_fails == 0 && estab_resets == 0, "Validator has no TCP connection failures when healthy")` |
| **Antithesis Angle** | Fault injection may cause peer connections to fail or get forcefully reset, revealing connection lifecycle instability |
| **Why It Matters** | Detects connection-level failures distinct from retransmissions — failed handshakes and forcefully reset established connections indicate peer communication breakdown |
| **Workload** | `parallel_driver_tcp_conn_failures.sh` — reads `/shared/validator_tcp_conn_failures` written by validator heartbeat loop |
| **Status** | ✅ Implemented |

### Validator TCP Reset Rate Is Bounded When Healthy

| | |
|---|---|
| **Type** | Safety (Always) |
| **Property** | When the validator is healthy, the ratio of TCP OutRsts to InSegs stays below 50% |
| **Invariant** | `ALWAYS(out_rsts / in_segs < 0.5, "Validator TCP reset rate is bounded when healthy")` |
| **Antithesis Angle** | Fault injection may cause resource exhaustion leading to socket backlog overflow and mass connection rejection |
| **Why It Matters** | High reset rates indicate the validator is rejecting connections — distinct from retransmissions (packet loss) and connection failures (establishment errors). Completes the TCP L4 health monitoring triad |
| **Workload** | `parallel_driver_tcp_outrsts.sh` — reads `/shared/validator_tcp_outrsts` written by validator heartbeat loop |
| **Status** | ✅ Implemented |

### Cross-Validator Account State Is Consistent After Transfer

| | |
|---|---|
| **Type** | Liveness (Sometimes) |
| **Property** | After a confirmed transfer, all responding validators agree on the genesis wallet's seqno and balance |
| **Invariant** | `SOMETIMES(seqno_agree && bal_agree && responded >= 2, "Cross-validator account state is consistent after transfer")` — evaluated only when at least 2 validators respond |
| **Antithesis Angle** | Fault injection may cause state replication lag or split-brain scenarios where validators diverge on account state |
| **Why It Matters** | L2 data consistency — goes beyond masterchain seqno agreement (L1) to verify that actual account data (seqno, balance) is consistent across validators after a transfer |
| **Workload** | `serial_driver_verify_transfer_across_validators.sh` — queries wallet seqno via `runmethod 85143` and balance via `getaccount` from all 3 liteservers |
| **Status** | ✅ Implemented |

### Cross-Validator Wallet Seqno Divergence Is Bounded

| | |
|---|---|
| **Type** | Safety (Always) |
| **Property** | Wallet seqnos reported by different validators never diverge by more than 1 |
| **Invariant** | `ALWAYS(max_seqno_diff <= 1, "Cross-validator wallet seqno divergence is bounded")` — evaluated when at least 2 validators respond with valid seqnos |
| **Antithesis Angle** | Fault injection may cause replication failures leading to split-brain where validators have fundamentally different state |
| **Why It Matters** | Catches split-brain scenarios — seqno divergence > 1 indicates state replication is broken, not merely delayed |
| **Workload** | `serial_driver_verify_transfer_across_validators.sh` — same workload as above, emits this Always guard alongside the Sometimes assertion |
| **Status** | ✅ Implemented |

### Masterchain Block Height Is Monotonically Non-Decreasing

| | |
|---|---|
| **Type** | Safety (Always) |
| **Property** | Once a masterchain seqno has been observed, the validator must never serve a lower one |
| **Invariant** | `ALWAYS(current_seqno >= previous_seqno, "Masterchain block height is monotonically non-decreasing")` — evaluated only when liteserver is reachable and query succeeds |
| **Antithesis Angle** | Fault injection may trigger consensus rollback where a validator serves a lower seqno than previously observed |
| **Why It Matters** | A seqno rollback is a consensus safety violation — the most critical class of blockchain bug. This is the first `anytime_` driver checking a blockchain data invariant (all prior `anytime_` scripts check infrastructure) |
| **Workload** | `anytime_masterchain_height_monotonic.sh` — queries `lite-client -c "last"`, compares against `/shared/_last_mc_seqno` |
| **Secondary** | `SOMETIMES(advancing_during_faults, "Masterchain height observed advancing during faults")` — emitted when height advances while heartbeat is stale (>30s), creating a branch point for fault+progress exploration |
| **Status** | ✅ Implemented |

### Cross-Validator Block Hash Matches at Same Height

| | |
|---|---|
| **Type** | Safety (Always) |
| **Property** | Validators must agree on the actual block content (root hash + file hash) at a given masterchain height — not just the seqno |
| **Invariant** | `ALWAYS(block_id_1 == block_id_2, "Cross-validator block hash matches at same height")` — evaluated when at least 2 of 3 validators respond with a block ID for the same seqno |
| **Antithesis Angle** | Fault injection may trigger consensus forks where validators produce different blocks at the same height |
| **Why It Matters** | The strongest consensus safety check — two validators with the same seqno but different block hashes indicates a consensus fork, the most critical safety violation in a blockchain |
| **Workload** | `anytime_block_hash_consensus.sh` — queries `lite-client -c "byseqno -1 8000000000000000 N"` on all 3 validators, compares full block ID strings `(-1,8000000000000000,N):ROOTHASH:FILEHASH` |
| **Secondary** | `SOMETIMES(true, "Block hash verified across multiple validators")` — emitted when ≥2 validators respond with matching hashes |
| **Status** | ✅ Implemented |

### Consensus Recovered After Fault

| | |
|---|---|
| **Type** | Liveness (Sometimes) |
| **Property** | After a detected fault (liteserver query failure or stale heartbeat >60s), block production resumes with a seqno higher than the last pre-fault seqno |
| **Invariant** | `SOMETIMES(current_seqno > last_good_seqno, "Consensus recovered after fault")` — evaluated only when a prior fault was recorded and liteserver now responds |
| **Antithesis Angle** | Creates a branch point at fault detection moments — amplifying bug-finding in recovery paths, consensus re-establishment, and state sync after interruption |
| **Why It Matters** | DATA-level recovery — a validator can have ports up but consensus stalled. This complements port-level recovery (`parallel_driver_recovery_observed.sh`) and unconditional height advancement (`eventually_block_height_advances.sh`) |
| **Workload** | `eventually_consensus_recovers.sh` — two-phase state machine persisted in `/shared/_consensus_recovery_state` |
| **Status** | ✅ Implemented |

### Wallet Balance Is Consistent Between Transfer Invocations

| | |
|---|---|
| **Type** | Safety (Always) |
| **Property** | After a confirmed transfer, the wallet balance must not increase between invocations (no incoming transfers exist, so balance can only decrease from outgoing transfers + fees) |
| **Invariant** | `ALWAYS(current_balance <= previous_balance, "Wallet balance is consistent between transfer invocations")` — evaluated when a previous balance was recorded and current balance is queryable |
| **Antithesis Angle** | Fault injection may cause acknowledged-but-lost writes where a transfer is confirmed (seqno advances) but the balance change is rolled back |
| **Why It Matters** | Detects the most critical data loss pattern: a transfer that was acknowledged but whose value effect was lost — invisible to seqno-only checks |
| **Workload** | `serial_driver_send_transfer.sh` — reads previous balance from `/shared/tx/last_confirmed_balance`, queries current balance via `getaccount` before sending new transfer |
| **Status** | ✅ Implemented |

### Transfer Read-Back Balance Verified

| | |
|---|---|
| **Type** | Liveness (Sometimes) |
| **Property** | The balance read-back verification passes after a confirmed transfer |
| **Invariant** | `SOMETIMES(current_balance <= previous_balance, "Transfer read-back balance verified")` — emitted when balance check passes between invocations |
| **Antithesis Angle** | Creates a branch point at balance verification moments, guiding exploration toward transfer durability scenarios |
| **Why It Matters** | Confirms the write-verify loop is actually exercising the read-back path — complements the Always guard by proving the check ran |
| **Workload** | `serial_driver_send_transfer.sh` — same workload as above, emitted alongside the Always assertion when balance is consistent |
| **Status** | ✅ Implemented |

### Duplicate Transfer BOC Is Correctly Rejected

| | |
|---|---|
| **Type** | Safety (Always) |
| **Property** | Re-sending a consumed transfer BOC (seqno=N after the contract advanced to N+1) must not advance the seqno again |
| **Invariant** | `ALWAYS(after_replay_seqno == after_transfer_seqno, "Duplicate transfer BOC is correctly rejected")` — evaluated after re-sending the same BOC that just succeeded |
| **Antithesis Angle** | Fault injection (network delays, reordering, duplicate delivery) creates exactly the conditions where replay bugs surface |
| **Why It Matters** | Replay attacks are one of the most dangerous blockchain vulnerabilities — if a signed transaction can be replayed after consumption, funds can be drained |
| **Workload** | `serial_driver_send_transfer.sh` — after a confirmed transfer, re-sends the same BOC file, waits 3s, re-queries seqno, and asserts it has not advanced |
| **Status** | ✅ Implemented |

### Transfer Replay Rejection Verified

| | |
|---|---|
| **Type** | Liveness (Sometimes) |
| **Property** | The replay protection test ran and passed at least once |
| **Invariant** | `SOMETIMES(true, "Transfer replay rejection verified")` — emitted when the replay test executes and the seqno correctly remains unchanged |
| **Antithesis Angle** | Creates a branch point at replay-test moments, guiding exploration toward duplicate-delivery scenarios |
| **Why It Matters** | Confirms the replay protection check is actually being exercised — complements the Always guard by proving the test ran |
| **Workload** | `serial_driver_send_transfer.sh` — same workload as above, emitted alongside the Always assertion when replay is rejected |
| **Status** | ✅ Implemented |

### All Acknowledged Transfers Persist in Final State

| | |
|---|---|
| **Type** | Safety (Always) |
| **Property** | Every wallet seqno confirmed by the transfer driver is still reflected in the final blockchain state at end of timeline |
| **Invariant** | `ALWAYS(current_seqno >= last_confirmed_seqno, "All acknowledged transfers persist in final state")` — evaluated once at end of timeline from all reachable validators |
| **Antithesis Angle** | Fault injection throughout the test is the stimulus; this is the verdict — the definitive data-loss check at timeline end |
| **Why It Matters** | The most important end-of-timeline check for a blockchain: confirmed transactions must never be lost. A seqno regression means acknowledged writes were rolled back — critical data loss |
| **Workload** | `finally_verify_transfers.sh` — reads `/shared/tx/last_confirmed_seqno`, queries wallet seqno via `runmethod 85143` from all reachable validators |
| **Secondary** | `SOMETIMES(true, "Transfer state verified at end of timeline")` — emitted when the check completes successfully, confirming the verification ran |
| **Status** | ✅ Implemented |

### All Validators Converged to Same Masterchain State at End of Timeline

| | |
|---|---|
| **Type** | Safety (Always) |
| **Property** | After all faults settle at timeline end, all responding validators must agree on the same masterchain block — the definitive consensus verdict |
| **Invariant** | `ALWAYS(block_ids_match, "All validators converged to same masterchain state at end of timeline")` — evaluated when ≥2 validators respond; seqno tolerance ≤1, but same seqno requires identical block ID (root hash + file hash) |
| **Antithesis Angle** | All fault injection has concluded — this checks whether the network recovered to a single consistent state |
| **Why It Matters** | The strongest end-of-timeline consensus check: same seqno + different block hash = fork = critical safety violation. Complements `anytime_block_hash_consensus.sh` (during faults) and `finally_verify_transfers.sh` (data persistence) |
| **Workload** | `finally_consensus_converged.sh` — queries `lite-client -c "last"` from all 3 validators' liteservers, compares full block ID strings `(-1,8000000000000000,N):ROOTHASH:FILEHASH` |
| **Secondary** | `SOMETIMES(all_3_match, "Consensus convergence verified across all validators")` — emitted when all 3 validators responded with identical masterchain state (seqno diff = 0) |
| **Skip Conditions** | Fewer than 2 validators reachable, lite-client unavailable, liteserver configs missing |
| **Status** | ✅ Implemented |

## Future Properties (for antithesis-workload)

### 2. Validator Engine Does Not Crash

| | |
|---|---|
| **Type** | Safety |
| **Property** | The validator-engine process does not crash unexpectedly |
| **Invariant** | `ALWAYS(process alive, "validator engine no crash")` checked by workload |
| **Antithesis Angle** | Fault injection (network, disk, scheduling) may trigger crashes |
| **Why It Matters** | Basic stability guarantee under adverse conditions |

### Validator Socket Count Is Not Monotonically Growing

| | |
|---|---|
| **Type** | Safety (Always) |
| **Property** | The validator's TCP socket count does not monotonically increase over consecutive readings |
| **Invariant** | `ALWAYS(!monotonic_growth OR growth < 50, "Validator socket count is not monotonically growing")` — evaluated over last 5 heartbeat readings; monotonic growth check is skipped during the first 60s after validator startup (grace period for initial connection ramp) |
| **Antithesis Angle** | Fault injection may trigger connection leaks if cleanup paths are missed |
| **Why It Matters** | Detects socket/connection leaks distinct from FD leaks — socket exhaustion can occur before FD limits |
| **Workload** | `parallel_driver_sock_growth.sh` — trajectory analysis over `/shared/validator_sock_history` |
| **Status** | ✅ Implemented |

### Validator Heartbeat Interval Is Regular When Healthy (Fix)

| | |
|---|---|
| **Note** | Fixed assertion visibility: added `sdk_always true` emissions on safe early-exit paths (first observation, interval unchanged, timestamp reset, backwards interval) so the assertion appears in snouty validate results even when preconditions prevent full evaluation |
| **Status** | ✅ Fixed (was cataloged but never appeared in results) |

### 3. Validator Engine Accepts Console Connections

| | |
|---|---|
| **Type** | Liveness |
| **Property** | The validator-engine console port becomes reachable |
| **Invariant** | `SOMETIMES(console_reachable, "console port reachable")` |
| **Antithesis Angle** | Network faults may prevent or delay console availability |
| **Why It Matters** | Operational readiness — operators must be able to manage the node |

### 4. State Persistence Survives Restart

| | |
|---|---|
| **Type** | Safety |
| **Property** | State written to RocksDB is readable after restart |
| **Invariant** | `ALWAYS(state_consistent, "state survives restart")` |
| **Antithesis Angle** | Crash + restart with fault injection during writes |
| **Why It Matters** | Data integrity is fundamental to blockchain correctness |

### In-Process C++ SDK Assertions — ADNL Layer (`adnl/adnl-peer.cpp`, `adnl/adnl-packet.cpp`)

**REACHABLE markers:**
- ADNL packet decrypted and processed
- ADNL peer reinit triggered
- ADNL channel created
- ADNL packet basic checks passed

**ALWAYS assertions:**
- ADNL incoming seqno is positive
- ADNL no duplicate seqno received
- ADNL confirm seqno does not exceed sent seqno
- ADNL channel confirm key matches
- ADNL huge message size matches on completion
- ADNL huge message hash verified
- ADNL outgoing query ID is unique
- ADNL message fits within MTU
- ADNL packet flags are valid subset
- ADNL packet has at most one message flag type
- ADNL packet source IDs are consistent
