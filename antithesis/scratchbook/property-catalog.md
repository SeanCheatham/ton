# Property Catalog: TON Blockchain Node

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

## Future Properties (for antithesis-workload)

### 2. Validator Engine Does Not Crash

| | |
|---|---|
| **Type** | Safety |
| **Property** | The validator-engine process does not crash unexpectedly |
| **Invariant** | `ALWAYS(process alive, "validator engine no crash")` checked by workload |
| **Antithesis Angle** | Fault injection (network, disk, scheduling) may trigger crashes |
| **Why It Matters** | Basic stability guarantee under adverse conditions |

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
