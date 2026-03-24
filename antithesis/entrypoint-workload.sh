#!/usr/bin/env bash
set -euo pipefail

# Entrypoint for the workload container.
# Waits for the validator to be ready, then emits setup_complete and sleeps.
# Test Composer will run test commands from /opt/antithesis/test/v1/ton/.

VALIDATOR_HOST="${VALIDATOR_HOST:-validator}"
VALIDATOR_PORT="${VALIDATOR_PORT:-30001}"

CONSOLE_PORT="${CONSOLE_PORT:-30002}"
LITE_PORT="${LITE_PORT:-30003}"

echo "Workload container starting..."
echo "Waiting for validator to be reachable..."

# Bounded wait — up to 20 seconds for the validator UDP port to come up
for i in $(seq 1 10); do
    if nc -z -w 1 -u "${VALIDATOR_HOST}" "${VALIDATOR_PORT}" 2>/dev/null; then
        echo "Validator is reachable on UDP port ${VALIDATOR_PORT}"
        break
    fi
    if [ "$i" -eq 10 ]; then
        echo "Warning: validator UDP not reachable after 20s, continuing anyway"
    fi
    sleep 2
done

# Wait for TCP subsystem ports (liteserver and console) to come up
echo "Waiting for validator TCP subsystem ports..."
for i in $(seq 1 10); do
    console_up=false
    lite_up=false
    nc -z -w 1 "${VALIDATOR_HOST}" "${CONSOLE_PORT}" 2>/dev/null && console_up=true
    nc -z -w 1 "${VALIDATOR_HOST}" "${LITE_PORT}" 2>/dev/null && lite_up=true
    if [[ "$console_up" == "true" && "$lite_up" == "true" ]]; then
        echo "Console (${CONSOLE_PORT}) and liteserver (${LITE_PORT}) TCP ports are up"
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
echo "Assertion catalog emitted."

# Signal that setup is complete
/usr/local/bin/setup-complete.sh

echo "Setup complete. Sleeping to allow Test Composer to run commands..."
exec sleep infinity
