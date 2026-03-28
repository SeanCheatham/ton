#!/usr/bin/env bash
set -euo pipefail

# Entrypoint for the workload container.
# Waits for all validators to be ready, then emits setup_complete and sleeps.
# Test Composer will run test commands from /opt/antithesis/test/v1/ton/.

VALIDATOR_HOST="${VALIDATOR_HOST:-ton-validator}"
VALIDATOR2_HOST="${VALIDATOR2_HOST:-ton-validator2}"
VALIDATOR3_HOST="${VALIDATOR3_HOST:-ton-validator3}"
VALIDATOR_PORT="${VALIDATOR_PORT:-30001}"

CONSOLE_PORT="${CONSOLE_PORT:-30002}"
LITE_PORT="${LITE_PORT:-30003}"

echo "Workload container starting..."

# Wait for all validators' UDP ports to come up. Each validator runs on the
# same internal port (30001) but a different container hostname.
for VAL_HOST in "${VALIDATOR_HOST}" "${VALIDATOR2_HOST}" "${VALIDATOR3_HOST}"; do
    echo "Waiting for ${VAL_HOST} to be reachable on UDP port ${VALIDATOR_PORT}..."
    for i in $(seq 1 10); do
        if nc -z -w 1 -u "${VAL_HOST}" "${VALIDATOR_PORT}" 2>/dev/null; then
            echo "${VAL_HOST} is reachable on UDP port ${VALIDATOR_PORT}"
            break
        fi
        if [ "$i" -eq 10 ]; then
            echo "Warning: ${VAL_HOST} UDP not reachable after 20s, continuing anyway"
        fi
        sleep 2
    done
done

# Wait for primary validator's TCP subsystem ports (liteserver and console).
echo "Waiting for primary validator TCP subsystem ports..."
for i in $(seq 1 10); do
    console_up=false
    lite_up=false
    nc -z -w 1 "${VALIDATOR_HOST}" "${CONSOLE_PORT}" 2>/dev/null && console_up=true
    nc -z -w 1 "${VALIDATOR_HOST}" "${LITE_PORT}" 2>/dev/null && lite_up=true
    if [[ "$console_up" == "true" && "$lite_up" == "true" ]]; then
        echo "Console (${CONSOLE_PORT}) and liteserver (${LITE_PORT}) TCP ports are up on ${VALIDATOR_HOST}"
        break
    fi
    if [ "$i" -eq 10 ]; then
        echo "Warning: TCP subsystem ports not all reachable after 20s, continuing anyway"
        echo "  Console ${CONSOLE_PORT}: ${console_up}, Liteserver ${LITE_PORT}: ${lite_up}"
    fi
    sleep 2
done

# Catalog SDK assertions before signaling setup complete
source /opt/antithesis/test/v1/ton/helper_sdk.sh
sdk_catalog_always "Validator subsystem consistency: all ports reachable together"
sdk_catalog_sometimes "Validator recovers fully after fault injection"
sdk_catalog_sometimes "Validator recovers mid-test after going down"
sdk_catalog_sometimes "Validator is alive during parallel driver phase"
sdk_catalog_always "Validator heartbeat is fresh when ports are reachable"
sdk_catalog_always "Validator downtime is bounded after initial startup"
sdk_catalog_always "Console port accepts and holds TCP connection"
sdk_catalog_always "Validator does not crash-loop or oscillate rapidly"
sdk_catalog_always "Validator database exists and grows when healthy"
sdk_catalog_always "Liteserver port accepts and holds TCP connection"
sdk_catalog_always "Validator heartbeat timestamp is monotonically non-decreasing"
sdk_catalog_always "Validator logs contain no fatal errors"
sdk_catalog_always "Validator file descriptor count is bounded"
sdk_catalog_always "Validator memory usage is bounded"
sdk_catalog_always "Validator log growth rate is bounded"
sdk_catalog_always "Network socket count is bounded"
sdk_catalog_always "RocksDB LOCK file exists when validator is healthy"
sdk_catalog_always "Validator config file remains valid JSON"
sdk_catalog_always "Validator is actively modifying database files"
sdk_catalog_always "Validator CPU time is advancing when healthy"
sdk_catalog_always "Validator process state is runnable"
sdk_catalog_always "Validator UDP socket is bound when healthy"
sdk_catalog_always "RocksDB WAL file count is bounded"
sdk_catalog_always "Validator I/O wait time is bounded"
sdk_catalog_always "TCP control ports are bound in kernel when healthy"
sdk_catalog_always "Validator disk usage is bounded"
sdk_catalog_always "RocksDB MANIFEST file exists when validator is healthy"
sdk_catalog_always "RocksDB CURRENT file is valid when validator is healthy"
sdk_catalog_always "Validator has no leaked deleted file descriptors"
sdk_catalog_always "Global config ton-global.config remains valid JSON"
sdk_catalog_always "Validator thread count is bounded"
sdk_catalog_sometimes "Network bytes transferred is non-zero when healthy"
sdk_catalog_always "RocksDB SST files exist when validator is healthy"
sdk_catalog_always "RocksDB CURRENT file references existing MANIFEST when validator is healthy"
sdk_catalog_always "Validator context switch rate is bounded when healthy"
sdk_catalog_always "Validator network bytes are increasing when healthy"
sdk_catalog_always "Network error and drop counts are zero when validator is healthy"
sdk_catalog_always "RocksDB LOG file contains no corruption or IO error warnings"
sdk_catalog_always "Validator swap usage is zero when healthy"
sdk_catalog_always "Validator oom_score is bounded when healthy"
sdk_catalog_always "Validator disk I/O bytes are progressing when healthy"
sdk_catalog_always "Validator has no unexpected file descriptor types"
sdk_catalog_always "RocksDB WAL-to-SST ratio is healthy when validator is running"
sdk_catalog_always "Validator peak memory (VmPeak) is bounded"
sdk_catalog_always "All expected validator metric files exist when healthy"
sdk_catalog_sometimes "Validator log contains expected initialization markers"
sdk_catalog_always "Validator has no zombie child processes when healthy"
sdk_catalog_always "Validator config.json contains expected structural keys"
sdk_catalog_always "Validator metric files are all fresh when healthy"
sdk_catalog_always "Validator TCP connections are in expected states when healthy"
sdk_catalog_always "RocksDB OPTIONS file exists and is non-empty when validator is healthy"
sdk_catalog_always "Validator has no stale RocksDB temporary files when healthy"
sdk_catalog_always "Validator critical signals are not blocked when healthy"
sdk_catalog_always "Validator RSS memory is not monotonically growing"
sdk_catalog_always "Validator database file permissions are correct when healthy"
sdk_catalog_always "Validator open FD count is not monotonically growing"
sdk_catalog_always "Validator thread count is not monotonically growing"
sdk_catalog_always "Validator keyring directory is non-empty when healthy"
sdk_catalog_sometimes "RocksDB compaction has occurred when validator is mature"
sdk_catalog_always "Validator process command line is stable when healthy"
sdk_catalog_always "RocksDB IDENTITY file is stable when validator is healthy"
sdk_catalog_always "Validator database directory count is non-decreasing when healthy"
sdk_catalog_always "RocksDB MANIFEST file size is bounded when validator is healthy"
sdk_catalog_always "Validator log file size is bounded"
sdk_catalog_always "Validator database directory structure is intact when healthy"
sdk_catalog_always "Validator virtual memory size is bounded"
sdk_catalog_always "RocksDB LOG file size is bounded when validator is healthy"
sdk_catalog_always "Validator has no core dump files when healthy"
sdk_catalog_always "Validator log mtime is fresh when healthy"
sdk_catalog_always "Validator memory mapping count is bounded when healthy"
sdk_catalog_sometimes "Lite-client can query validator and get a response"
sdk_catalog_always "RocksDB SST file count is non-decreasing when healthy"
sdk_catalog_sometimes "Validator log shows block processing activity"
sdk_catalog_always "Validator startup time is bounded"
sdk_catalog_always "Validator listening socket count matches expected"
sdk_catalog_sometimes "Validator survives malformed ADNL protocol traffic"
sdk_catalog_always "Validator process is single-threaded-leader stable"
sdk_catalog_sometimes "Validator survives malformed TCP traffic on liteserver port"
sdk_catalog_sometimes "Validator survives malformed TCP traffic on console port"
sdk_catalog_sometimes "Validator survives TCP connection flood on all ports"
sdk_catalog_sometimes "Validator survives slow-drip TCP connections"
sdk_catalog_always "Validator log does not contain private key material"
sdk_catalog_always "Validator keyring file permissions are restrictive when healthy"
sdk_catalog_sometimes "Validator survives rapid TCP reconnection storm"
sdk_catalog_always "Validator log contains no memory allocation failures"
sdk_catalog_sometimes "All ports reachable after faults settle"
sdk_catalog_always "Validator thread count meets minimum when healthy"
sdk_catalog_sometimes "Validator survives oversized UDP payloads"
sdk_catalog_always "Validator heartbeat file contains valid data when present"
sdk_catalog_sometimes "Validator survives concurrent lite-client queries"
sdk_catalog_always "Validator log output is valid UTF-8"
sdk_catalog_always "Validator initial state is valid before faults"
sdk_catalog_always "Validator config file content is stable over time"
sdk_catalog_always "Validator environment configuration is stable"
sdk_catalog_sometimes "Validator survives partial ADNL handshake flood"
sdk_catalog_sometimes "Validator survives simultaneous multi-port adversarial traffic"
sdk_catalog_always "Validator process scheduling priority is stable when healthy"
sdk_catalog_sometimes "Validator survives time-bomb TCP connections"
sdk_catalog_sometimes "Validator survives protocol confusion attacks on all ports"
sdk_catalog_always "Validator listening socket accept queue is bounded"
sdk_catalog_always "Validator syscall I/O counts are advancing when healthy"
sdk_catalog_always "RocksDB LOG contains no write stall indicators when validator is healthy"
sdk_catalog_always "Validator heartbeat interval is regular when healthy"
sdk_catalog_sometimes "Validator survives empty UDP packets"
sdk_catalog_always "Validator resource limits are adequate for operation"
sdk_catalog_always "Validator log non-fatal error count is bounded when healthy"
sdk_catalog_always "RSS-to-VmSize ratio is bounded when validator is healthy"
sdk_catalog_always "Validator memory mapping count is not monotonically growing"
sdk_catalog_always "Validator socket count is not monotonically growing"
sdk_catalog_always "TCP retransmission rate is bounded when validator is healthy"
sdk_catalog_always "Validator has no IP-level input errors when healthy"
sdk_catalog_always "Validator has no UDP buffer errors when healthy"
sdk_catalog_always "Validator TCP reset rate is bounded when healthy"
# Multi-validator consensus assertions
sdk_catalog_sometimes "Consensus quorum: at least 2 of 3 validators have fresh heartbeats"
sdk_catalog_sometimes "All 3 validators are reachable on their UDP ports"
sdk_catalog_sometimes "Masterchain block height advances over time"
sdk_catalog_sometimes "A TON transfer completed successfully"
sdk_catalog_sometimes "Multiple validators returned consistent state"
sdk_catalog_sometimes "Liteserver handles diverse query types"
# Data integrity assertions (from recent plans)
sdk_catalog_always "Masterchain block height is monotonically non-decreasing"
sdk_catalog_sometimes "Masterchain height observed advancing during faults"
sdk_catalog_always "Cross-validator block hash matches at same height"
sdk_catalog_sometimes "Block hash verified across multiple validators"
sdk_catalog_always "Wallet balance is consistent between transfer invocations"
sdk_catalog_sometimes "Transfer read-back balance verified"
sdk_catalog_always "Duplicate transfer BOC is correctly rejected"
sdk_catalog_sometimes "Transfer replay rejection verified"
sdk_catalog_sometimes "Cross-validator account state is consistent after transfer"
sdk_catalog_always "Cross-validator wallet seqno divergence is bounded"
sdk_catalog_always "All acknowledged transfers persist in final state"
sdk_catalog_sometimes "Transfer state verified at end of timeline"
sdk_catalog_always "All validators converged to same masterchain state at end of timeline"
sdk_catalog_always "Account state consistent across validators at end of timeline"
sdk_catalog_sometimes "Consensus convergence verified across all validators"
sdk_catalog_sometimes "Consensus recovered after fault"
sdk_catalog_sometimes "Liteserver getblock query returned valid data"
sdk_catalog_sometimes "Liteserver transaction history query returned valid data"
sdk_catalog_always "Historical block retrieval returns consistent data"
sdk_catalog_sometimes "Historical block transactions listed successfully"
sdk_catalog_sometimes "Liteserver block proof chain verified successfully"
sdk_catalog_always "Validator survives malformed BOC submissions"
sdk_catalog_sometimes "Malformed BOC gracefully rejected"
sdk_catalog_always "Wallet seqno advances by at most 1 per block under contention"
sdk_catalog_sometimes "Concurrent transfer contention observed"
echo "Assertion catalog emitted."

# Signal that setup is complete
/usr/local/bin/setup-complete.sh

echo "Setup complete. Sleeping to allow Test Composer to run commands..."
exec sleep infinity
