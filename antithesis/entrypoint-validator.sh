#!/usr/bin/env bash
set -euo pipefail

# Entrypoint for the TON validator-engine in the Antithesis environment.
# Starts validator-engine with a minimal local configuration that includes
# liteserver (TCP) and control/console (TCP) interfaces in addition to the
# main UDP P2P port.

DB_ROOT="/var/ton-work/db"
GLOBAL_CONFIG="${DB_ROOT}/ton-global.config"
VALIDATOR_PORT="${VALIDATOR_PORT:-30001}"
CONSOLE_PORT="${CONSOLE_PORT:-30002}"
LITE_PORT="${LITE_PORT:-30003}"
THREADS="${THREADS:-2}"
VERBOSITY="${VERBOSITY:-3}"
IP="0.0.0.0"

mkdir -p "${DB_ROOT}/keyring"

# If no global config exists, create a minimal one for standalone operation
if [ ! -f "${GLOBAL_CONFIG}" ]; then
    echo '{"@type":"config.global","dht":{"@type":"dht.config.global","k":6,"a":3,"static_nodes":{"@type":"dht.nodes","nodes":[]}},"liteservers":[],"validator":{"@type":"validator.config.global","zero_state":{"workchain":-1,"shard":-9223372036854775808,"seqno":0,"root_hash":"AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE=","file_hash":"AgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgI="}}}' > "${GLOBAL_CONFIG}"
fi

# Initialize local config if not present
if [ ! -f "${DB_ROOT}/config.json" ]; then
    echo "Generating control interface key..."
    # generate-random-id -m id outputs 3 lines:
    #   1: {"@type":"pk.ed25519","key":"<base64>"}       (private key)
    #   2: {"@type":"pub.ed25519","key":"<base64>"}      (public key)
    #   3: {"@type":"adnl.id.short","id":"<base64>"}     (short id / key hash)
    CONTROL_OUTPUT=$(generate-random-id -m id)
    CONTROL_PRIV=$(echo "$CONTROL_OUTPUT" | sed -n '1p')
    CONTROL_PUB_HASH=$(echo "$CONTROL_OUTPUT" | sed -n '3p' | jq -r '.id')

    # Build local config with liteserver (random key) and control interface
    cat > /tmp/local-config.json <<LOCALEOF
{
    "@type": "config.local",
    "local_ids": [],
    "dht": [],
    "validators": [],
    "liteservers": [
        {"@type": "liteserver.config.random.local", "port": ${LITE_PORT}}
    ],
    "control": [
        {
            "@type": "control.config.local",
            "priv": ${CONTROL_PRIV},
            "pub": "${CONTROL_PUB_HASH}",
            "port": ${CONSOLE_PORT}
        }
    ]
}
LOCALEOF

    echo "Local config:"
    cat /tmp/local-config.json

    echo "Initializing validator-engine with liteserver and console..."
    validator-engine \
        -C "${GLOBAL_CONFIG}" \
        --db "${DB_ROOT}" \
        --ip "${IP}:${VALIDATOR_PORT}" \
        -c /tmp/local-config.json || true

    echo "Initialization complete. Config written to ${DB_ROOT}/config.json"
fi

# Start background heartbeat writer — writes epoch timestamp to shared volume
# every 5 seconds so the workload can detect hangs/deadlocks.
echo "Starting heartbeat writer..."
while true; do
    date +%s > /shared/validator_heartbeat
    # Write DB directory size (bytes) for data-integrity monitoring
    if [ -d "/var/ton-work/db" ]; then
        du -sb /var/ton-work/db 2>/dev/null | cut -f1 > /shared/validator_db_size
    fi
    # Write open file descriptor count for resource monitoring
    FD_COUNT=$(ls /proc/1/fd 2>/dev/null | wc -l || echo "-1")
    echo "$FD_COUNT" > /shared/validator_fd_count
    # Write resident set size (KB) for memory monitoring
    RSS_KB=$(awk '/VmRSS/{print $2}' /proc/1/status 2>/dev/null || echo "-1")
    echo "$RSS_KB" > /shared/validator_mem_rss
    # Write open TCP socket count for connection leak monitoring
    SOCK_COUNT=$(wc -l < /proc/1/net/tcp 2>/dev/null || echo "-1")
    # Subtract 1 for the header line
    SOCK_COUNT=$((SOCK_COUNT - 1))
    echo "$SOCK_COUNT" > /shared/validator_sock_count
    # Write RocksDB LOCK file existence for DB integrity monitoring
    # RocksDB may place the LOCK file in a subdirectory (e.g., /var/ton-work/db/celldb/LOCK)
    LOCK_COUNT=$(find /var/ton-work/db -name LOCK -type f 2>/dev/null | head -1 | wc -l)
    if [ "$LOCK_COUNT" -gt 0 ]; then
        echo "1" > /shared/validator_db_lock
    else
        echo "0" > /shared/validator_db_lock
    fi
    # Write config.json validity for data integrity monitoring
    if [ -f "/var/ton-work/db/config.json" ]; then
        if jq empty /var/ton-work/db/config.json 2>/dev/null; then
            echo "1" > /shared/validator_config_valid
        else
            echo "0" > /shared/validator_config_valid
        fi
    else
        echo "-1" > /shared/validator_config_valid
    fi
    # Write most recent DB file modification time for activity monitoring
    DB_MTIME=$(find /var/ton-work/db -type f -printf '%T@\n' 2>/dev/null | sort -rn | head -1 | cut -d. -f1)
    echo "${DB_MTIME:--1}" > /shared/validator_db_mtime
    # Write cumulative CPU time (user + system ticks) for activity monitoring
    CPU_TICKS=$(awk '{print $14 + $15}' /proc/1/stat 2>/dev/null || echo "-1")
    echo "$CPU_TICKS" > /shared/validator_cpu_ticks
    # Write process state (R=running, S=sleeping, D=uninterruptible, T=stopped, Z=zombie)
    PROC_STATE=$(awk '/^State:/{print $2}' /proc/1/status 2>/dev/null || echo "?")
    echo "$PROC_STATE" > /shared/validator_proc_state
    # Write UDP socket bound status for port 30001 (0x7531 in hex)
    # Only write once the validator process is PID 1 (after exec); before that,
    # PID 1 is bash and the UDP socket won't be bound yet — writing "0" would
    # cause a false violation if the workload reads the stale value.
    if grep -q validator-engine /proc/1/cmdline 2>/dev/null; then
        UDP_BOUND=$(awk '$2 ~ /:7531$/ {found=1} END {print found+0}' /proc/1/net/udp 2>/dev/null || echo "-1")
        echo "$UDP_BOUND" > /shared/validator_udp_bound
    fi
    # Write RocksDB WAL (.log) file count for compaction health monitoring
    WAL_COUNT=$(find /var/ton-work/db -maxdepth 2 -name "*.log" -type f 2>/dev/null | wc -l)
    echo "$WAL_COUNT" > /shared/validator_wal_count
    # Write cumulative block I/O delay ticks (field 42 of /proc/1/stat)
    IO_TICKS=$(awk '{print $42}' /proc/1/stat 2>/dev/null || echo "-1")
    echo "$IO_TICKS" > /shared/validator_io_ticks
    # Write total disk usage of /var/ton-work for disk budget monitoring
    DISK_USAGE=$(du -sb /var/ton-work 2>/dev/null | cut -f1 || echo "-1")
    echo "$DISK_USAGE" > /shared/validator_disk_usage
    # Write RocksDB MANIFEST file count for data integrity monitoring
    MANIFEST_COUNT=$(find /var/ton-work/db -maxdepth 2 -name "MANIFEST-*" -type f 2>/dev/null | wc -l)
    echo "$MANIFEST_COUNT" > /shared/validator_manifest_count
    # Write TCP control ports bound status (30002=0x7532, 30003=0x7533)
    # Only write once the validator process is PID 1 (after exec) to avoid stale "0"
    if grep -q validator-engine /proc/1/cmdline 2>/dev/null; then
        TCP_PORTS=$(cat /proc/1/net/tcp 2>/dev/null)
        if echo "$TCP_PORTS" | grep -qi "00000000:7532.*0A" && echo "$TCP_PORTS" | grep -qi "00000000:7533.*0A"; then
            echo 1 > /shared/validator_tcp_bound
        else
            echo 0 > /shared/validator_tcp_bound
        fi
    fi
    # Write RocksDB CURRENT file validity (root of metadata chain: CURRENT → MANIFEST → SST)
    CURRENT_FILE=$(find /var/ton-work/db -maxdepth 2 -name CURRENT -type f 2>/dev/null | head -1)
    if [ -n "$CURRENT_FILE" ] && [ -s "$CURRENT_FILE" ]; then
        echo "1" > /shared/validator_current_valid
    else
        echo "0" > /shared/validator_current_valid
    fi
    # Write count of leaked deleted file descriptors
    DELETED_FDS=$(ls -la /proc/1/fd 2>/dev/null | grep -c '(deleted)' || echo "0")
    echo "$DELETED_FDS" > /shared/validator_deleted_fds
    # Write ton-global.config JSON validity
    if [ -f "/var/ton-work/db/ton-global.config" ]; then
        if jq empty /var/ton-work/db/ton-global.config 2>/dev/null; then
            echo "1" > /shared/validator_global_config_valid
        else
            echo "0" > /shared/validator_global_config_valid
        fi
    else
        echo "-1" > /shared/validator_global_config_valid
    fi
    sleep 5
done &

echo "Starting validator-engine..."
exec validator-engine \
    -C "${GLOBAL_CONFIG}" \
    --db "${DB_ROOT}" \
    --ip "${IP}:${VALIDATOR_PORT}" \
    --threads "${THREADS}" \
    --verbosity "${VERBOSITY}" \
    --logname /shared/validator.log
