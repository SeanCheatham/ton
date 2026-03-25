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
