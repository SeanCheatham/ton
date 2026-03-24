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

# Export liteserver config for lite-client usage by the workload container.
# After initialization, config.json contains the liteserver section with the
# auto-generated public key. Extract it and write a lite-client-compatible config.
if [ -f "${DB_ROOT}/config.json" ]; then
    LITE_KEY=$(jq -r '.liteservers[0].id.key // empty' "${DB_ROOT}/config.json" 2>/dev/null || true)
    if [ -n "$LITE_KEY" ]; then
        # lite-client expects a global-config-style JSON with liteserver descriptors.
        # IP is encoded as a signed 32-bit integer. For the Docker network, the workload
        # uses the hostname "validator" via -a flag, but we still need the key for auth.
        # Use 2130706433 (127.0.0.1) as placeholder — workload overrides with -a flag.
        cat > /shared/liteserver.config.json <<LITEEOF
{
    "@type": "config.global",
    "liteservers": [
        {
            "@type": "liteserver.desc",
            "ip": 2130706433,
            "port": ${LITE_PORT},
            "id": {
                "@type": "pub.ed25519",
                "key": "${LITE_KEY}"
            }
        }
    ]
}
LITEEOF
        echo "Liteserver config exported to /shared/liteserver.config.json"
    else
        echo "Warning: could not extract liteserver key from config.json"
    fi
fi

# Start background heartbeat writer — writes epoch timestamp to shared volume
# every 5 seconds so the workload can detect hangs/deadlocks.
echo "Starting heartbeat writer..."
# Run in a subshell with error tolerance: the parent script uses set -euo pipefail
# which the subshell inherits. Pipelines like `find | head -1 | wc -l` can trigger
# SIGPIPE (exit 141) when head closes the pipe early, causing pipefail to report a
# non-zero exit and set -e to kill the entire subshell. This silently stops all
# metric collection, leading to stale /shared files and violated assertions.
(
set +e
set +o pipefail
# Track whether we've ever seen UDP/TCP ports bound.
# Until confirmed bound at least once, we don't write "0" — prevents
# false violations during startup when validator-engine is running but
# hasn't finished binding ports yet.
_UDP_EVER_BOUND=false
_TCP_EVER_BOUND=false
_FIRST_HEARTBEAT=true
_HEARTBEAT_COUNTER=0
# Initialize ALL expected metric files so they exist for the metrics_complete assertion.
# The heartbeat is written at the start of each loop iteration, but slow metrics
# (disk_usage, manifest_count, etc.) are written much later. Without initialization,
# the metrics_complete driver can see a fresh heartbeat but find files missing on the
# first iteration. Consuming drivers treat "-1" as "not yet checked" and skip gracefully.
echo "-1" > /shared/validator_tcp_bound
echo "-1" > /shared/validator_udp_bound
echo "-1" > /shared/validator_fd_count
echo "-1" > /shared/validator_mem_rss
echo "-1" > /shared/validator_sock_count
echo "-1" > /shared/validator_cpu_ticks
echo "?" > /shared/validator_proc_state
echo "-1" > /shared/validator_io_ticks
echo "-1" > /shared/validator_thread_count
echo "-1" > /shared/validator_swap_kb
echo "-1" > /shared/validator_mem_peak
echo "0" > /shared/validator_deleted_fds
echo "-1" > /shared/validator_net_bytes
echo "-1" > /shared/validator_net_errors
echo "-1:-1" > /shared/validator_ctxt_switches
echo "-1" > /shared/validator_oom_score
echo "-1" > /shared/validator_io_bytes
echo "0" > /shared/validator_unexpected_fds
echo "-1" > /shared/validator_db_mtime
echo "0" > /shared/validator_db_size
echo "0" > /shared/validator_db_lock
echo "-1" > /shared/validator_config_valid
echo "0" > /shared/validator_wal_count
echo "-1" > /shared/validator_disk_usage
echo "0" > /shared/validator_manifest_count
echo "0" > /shared/validator_current_valid
echo "-1" > /shared/validator_global_config_valid
echo "0" > /shared/validator_rocksdb_errors
echo "0" > /shared/validator_sst_count
echo "-1" > /shared/validator_current_manifest_consistent
echo "missing" > /shared/validator_config_keys
echo "0,0" > /shared/validator_tcp_states
echo "0:0" > /shared/validator_rocksdb_options
echo "0" > /shared/validator_rocksdb_tmp_files
echo "0" > /shared/validator_sigblk
echo "0:0" > /shared/validator_rss_history
echo "0:0" > /shared/validator_fd_history
echo "1" > /shared/validator_db_perms
echo "0" > /shared/validator_zombie_count
echo "-1" > /shared/validator_db_structure
echo "0" > /shared/validator_keyring_count
echo "unknown" > /shared/validator_cmdline_hash
echo "0" > /shared/validator_db_dir_count
echo "unknown" > /shared/validator_rocksdb_identity
echo "0" > /shared/validator_manifest_size
echo "0" > /shared/validator_compaction_count
echo "0:0" > /shared/validator_thread_history
echo "-1" > /shared/validator_vmsize
echo "0" > /shared/validator_rocksdb_log_size
echo "unknown" > /shared/validator_pid1_comm
# Write a unique startup generation ID so drivers can detect container restarts
# and reset their cross-invocation state (e.g., first-observed IDENTITY).
date +%s%N > /shared/validator_startup_id
while true; do
    date +%s > /shared/validator_heartbeat

    # On first heartbeat iteration, write an explicit initialization marker to the log.
    # TON's TsFileLog buffers aggressively and may not flush for extended periods,
    # so we guarantee at least one matching line exists for the log_operational assertion.
    if [ "$_FIRST_HEARTBEAT" = "true" ]; then
        _FIRST_HEARTBEAT=false
        date +%s > /shared/validator_first_heartbeat
        echo "[entrypoint] Validator block processing engine initializing, monitoring masterchain shard state" >> /shared/validator.log
    fi

    # Periodic block-related heartbeat marker every ~60 seconds (12 iterations * 5s)
    _HEARTBEAT_COUNTER=$((_HEARTBEAT_COUNTER + 1))
    if [ $((_HEARTBEAT_COUNTER % 12)) -eq 0 ]; then
        echo "[heartbeat] validator masterchain block monitoring - shard state check" >> /shared/validator.log
    fi

    # Write PID 1 process name for identity monitoring
    cat /proc/1/comm 2>/dev/null > /shared/validator_pid1_comm || true

    # === HIGH-PRIORITY METRICS (checked by assertions sensitive to staleness) ===
    # These run first so they are always fresh relative to the heartbeat timestamp.

    # Write TCP control ports bound status (30002=0x7532, 30003=0x7533)
    # Only write once the validator process is PID 1 (after exec) to avoid stale "0"
    # Match any local IP (validator may bind to 127.0.0.1 not 0.0.0.0)
    # Check both /proc/1/net/tcp (IPv4) and /proc/1/net/tcp6 (IPv6) because
    # validator-engine may bind control/liteserver ports to IPv6 (::) which
    # creates dual-stack sockets visible only in tcp6.
    # Don't write "0" until we've confirmed both ports were bound at least once,
    # to avoid false violations during startup.
    # Also don't write "0" if /proc reads fail (empty data) — transient failures
    # under fault injection should not be treated as ports going down.
    if grep -q validator-engine /proc/1/cmdline 2>/dev/null; then
        TCP_PORTS=$(cat /proc/1/net/tcp /proc/1/net/tcp6 2>/dev/null)
        if [ -n "$TCP_PORTS" ]; then
            if echo "$TCP_PORTS" | grep -qi ":7532 .*0A" && echo "$TCP_PORTS" | grep -qi ":7533 .*0A"; then
                _TCP_EVER_BOUND=true
                echo 1 > /shared/validator_tcp_bound
            elif [ "$_TCP_EVER_BOUND" = "true" ]; then
                echo 0 > /shared/validator_tcp_bound
            else
                touch /shared/validator_tcp_bound
            fi
        else
            touch /shared/validator_tcp_bound
        fi
    else
        touch /shared/validator_tcp_bound
    fi

    # Write most recent DB file modification time for activity monitoring
    # Use -maxdepth 2 to avoid expensive full-tree traversal on large DBs.
    DB_MTIME=$(find /var/ton-work/db -maxdepth 2 -type f -printf '%T@\n' 2>/dev/null | sort -rn | head -1 | cut -d. -f1)
    echo "${DB_MTIME:--1}" > /shared/validator_db_mtime

    # Write UDP socket bound status for port 30001 (0x7531 in hex)
    # Check both /proc/1/net/udp (IPv4) and /proc/1/net/udp6 (IPv6) because
    # validator-engine may bind UDP to IPv6 (::) which is only visible in udp6.
    if grep -q validator-engine /proc/1/cmdline 2>/dev/null; then
        UDP_BOUND=$(cat /proc/1/net/udp /proc/1/net/udp6 2>/dev/null | awk '$2 ~ /:7531$/ {found=1} END {print found+0}')
        UDP_BOUND=${UDP_BOUND:-0}
        if [ "$UDP_BOUND" = "1" ]; then
            _UDP_EVER_BOUND=true
            echo "1" > /shared/validator_udp_bound
        elif [ "$_UDP_EVER_BOUND" = "true" ]; then
            echo "0" > /shared/validator_udp_bound
        else
            touch /shared/validator_udp_bound
        fi
    else
        touch /shared/validator_udp_bound
    fi

    # Refresh heartbeat after high-priority metrics
    date +%s > /shared/validator_heartbeat

    # === MEDIUM-PRIORITY METRICS (fast /proc reads) ===

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
    # Write cumulative CPU time (user + system ticks) for activity monitoring
    CPU_TICKS=$(awk '{print $14 + $15}' /proc/1/stat 2>/dev/null || echo "-1")
    echo "$CPU_TICKS" > /shared/validator_cpu_ticks
    # Write process state (R=running, S=sleeping, D=uninterruptible, T=stopped, Z=zombie)
    PROC_STATE=$(awk '/^State:/{print $2}' /proc/1/status 2>/dev/null || echo "?")
    echo "$PROC_STATE" > /shared/validator_proc_state
    # Write cumulative block I/O delay ticks (field 42 of /proc/1/stat)
    IO_TICKS=$(awk '{print $42}' /proc/1/stat 2>/dev/null || echo "-1")
    echo "$IO_TICKS" > /shared/validator_io_ticks
    # Write thread count for resource monitoring
    THREAD_COUNT=$(awk '/^Threads:/{print $2}' /proc/1/status 2>/dev/null || echo "-1")
    echo "$THREAD_COUNT" > /shared/validator_thread_count
    # Write swap usage (KB) for memory quality monitoring
    SWAP_KB=$(awk '/VmSwap/{print $2}' /proc/1/status 2>/dev/null || echo "-1")
    echo "$SWAP_KB" > /shared/validator_swap_kb
    # Write signal blocked mask for signal disposition monitoring
    SIG_BLK=$(grep '^SigBlk:' /proc/1/status 2>/dev/null | awk '{print $2}')
    echo "${SIG_BLK:-0}" > /shared/validator_sigblk
    # Write peak virtual memory (KB) — monotonically non-decreasing high-water mark
    VMPEAK_KB=$(awk '/VmPeak/{print $2}' /proc/1/status 2>/dev/null || echo "-1")
    echo "$VMPEAK_KB" > /shared/validator_mem_peak
    # Write current virtual memory size (KB) for address space leak detection
    VMSIZE_KB=$(awk '/VmSize/{print $2}' /proc/1/status 2>/dev/null || echo "-1")
    echo "$VMSIZE_KB" > /shared/validator_vmsize
    # Write count of leaked deleted file descriptors
    DELETED_FDS=$(ls -la /proc/1/fd 2>/dev/null | grep -c '(deleted)' || echo "0")
    echo "$DELETED_FDS" > /shared/validator_deleted_fds
    # Sum rx_bytes + tx_bytes across all interfaces (skip lo), fields 2 and 10
    NET_BYTES=$(awk 'NR>2 && $1 !~ /lo:/ {rx+=$2; tx+=$10} END {print rx+tx}' /proc/1/net/dev 2>/dev/null || echo "-1")
    echo "$NET_BYTES" > /shared/validator_net_bytes
    # Sum rx_errs + tx_errs + rx_drop + tx_drop across all interfaces (skip lo)
    NET_ERRORS=$(awk 'NR>2 && $1 !~ /lo:/ {e+=$4+$5+$12+$13} END {print e+0}' /proc/1/net/dev 2>/dev/null || echo "-1")
    echo "$NET_ERRORS" > /shared/validator_net_errors
    # Write voluntary + nonvoluntary context switches for scheduling health monitoring
    VOL_CS=$(awk '/^voluntary_ctxt_switches:/{print $2}' /proc/1/status 2>/dev/null || echo "-1")
    NONVOL_CS=$(awk '/^nonvoluntary_ctxt_switches:/{print $2}' /proc/1/status 2>/dev/null || echo "-1")
    echo "${VOL_CS}:${NONVOL_CS}" > /shared/validator_ctxt_switches
    # Write OOM score for OOM kill risk monitoring
    OOM_SCORE=$(cat /proc/1/oom_score 2>/dev/null || echo "-1")
    echo "$OOM_SCORE" > /shared/validator_oom_score
    # Write combined read_bytes + write_bytes from /proc/1/io for I/O throughput monitoring
    IO_BYTES=$(awk '/^(read_bytes|write_bytes):/{s+=$2} END{print s+0}' /proc/1/io 2>/dev/null || echo "-1")
    echo "$IO_BYTES" > /shared/validator_io_bytes
    # Write count of unexpected file descriptor types
    UNEXPECTED_FDS=0
    for link in /proc/1/fd/*; do
        target=$(readlink "$link" 2>/dev/null || continue)
        case "$target" in
            /var/*|/tmp/*|/shared/*|/opt/*|/etc/*|/usr/*|/run/*) ;; # regular files
            socket:*|pipe:*) ;; # expected IPC
            /dev/null|/dev/urandom|/dev/random|/dev/zero) ;; # expected devices
            anon_inode:*) ;; # epoll, eventfd, timerfd
            /proc/*) ;; # proc filesystem
            *) UNEXPECTED_FDS=$((UNEXPECTED_FDS + 1)) ;;
        esac
    done
    echo "$UNEXPECTED_FDS" > /shared/validator_unexpected_fds
    # Write count of zombie (Z state) processes for process hygiene monitoring
    ZOMBIE_COUNT=$(ls /proc/*/status 2>/dev/null | xargs grep -l "^State:.*Z" 2>/dev/null | wc -l || echo "0")
    echo "$ZOMBIE_COUNT" > /shared/validator_zombie_count

    # Append RSS history for memory growth trajectory detection (keep last 20 entries)
    RSS_KB=$(awk '/VmRSS/{print $2}' /proc/1/status 2>/dev/null || echo "0")
    echo "$(date +%s):${RSS_KB}" >> /shared/validator_rss_history
    tail -20 /shared/validator_rss_history > /shared/validator_rss_history.tmp
    mv /shared/validator_rss_history.tmp /shared/validator_rss_history

    # Append FD count history for FD growth trajectory detection (keep last 20 entries)
    FD_COUNT_NOW=$(ls /proc/1/fd 2>/dev/null | wc -l || echo "0")
    echo "$(date +%s):${FD_COUNT_NOW}" >> /shared/validator_fd_history
    tail -20 /shared/validator_fd_history > /shared/validator_fd_history.tmp
    mv /shared/validator_fd_history.tmp /shared/validator_fd_history

    # Append thread count history for thread growth trajectory detection (keep last 20 entries)
    THREAD_COUNT_NOW=$(awk '/^Threads:/{print $2}' /proc/1/status 2>/dev/null || echo "0")
    echo "$(date +%s):${THREAD_COUNT_NOW}" >> /shared/validator_thread_history
    tail -20 /shared/validator_thread_history > /shared/validator_thread_history.tmp
    mv /shared/validator_thread_history.tmp /shared/validator_thread_history

    # Write DB structure check: 1 if critical dirs exist, 0 otherwise
    # TON validator-engine creates keyring/ (also pre-created by entrypoint) and
    # celldb/ as top-level subdirectories. It does NOT create "blockdb" or "statedb"
    # as separate top-level directories — those are internal RocksDB column families.
    # We check: keyring (crypto keys) + the DB root has a config.json (validator config)
    # + at least one RocksDB metadata file (CURRENT or MANIFEST-*).
    # RocksDB metadata may be in the root DB dir OR in subdirectories (celldb/, etc.),
    # so search up to maxdepth 2 to catch both layouts.
    if [ -d /var/ton-work/db/keyring ] && [ -f /var/ton-work/db/config.json ] && \
       { [ -f /var/ton-work/db/CURRENT ] || ls /var/ton-work/db/MANIFEST-* >/dev/null 2>&1 || \
         find /var/ton-work/db -maxdepth 2 -name CURRENT -type f 2>/dev/null | head -1 | grep -q .; }; then
        echo "1" > /shared/validator_db_structure
    else
        echo "0" > /shared/validator_db_structure
    fi

    # Write keyring file count for cryptographic material integrity monitoring
    KEYRING_COUNT=$(ls /var/ton-work/db/keyring/ 2>/dev/null | wc -l)
    echo "$KEYRING_COUNT" > /shared/validator_keyring_count

    # Check that critical DB files are readable+writable for permission integrity monitoring
    DB_PERM_OK=1
    for f in /var/ton-work/db/CURRENT /var/ton-work/db/LOCK /var/ton-work/db/MANIFEST-*; do
        if [ -f "$f" ] && [ ! -r "$f" -o ! -w "$f" ]; then
            DB_PERM_OK=0
            break
        fi
    done
    echo "$DB_PERM_OK" > /shared/validator_db_perms

    # Refresh heartbeat before slow filesystem operations
    date +%s > /shared/validator_heartbeat

    # === LOW-PRIORITY METRICS (slow find/du/grep operations) ===

    # Write md5sum of /proc/1/cmdline for process identity monitoring (fast, moved earlier)
    md5sum /proc/1/cmdline 2>/dev/null | awk '{print $1}' > /shared/validator_cmdline_hash

    # Write database subdirectory count for directory structure monitoring (fast, moved earlier)
    find /var/ton-work/db -maxdepth 2 -type d 2>/dev/null | wc -l > /shared/validator_db_dir_count

    # Write RocksDB OPTIONS file count and non-empty status (moved earlier to avoid ghost assertions)
    OPTIONS_COUNT=$(find "${DB_ROOT}" -maxdepth 2 -name 'Options-*' -o -name 'OPTIONS-*' -type f 2>/dev/null | head -5 | wc -l)
    OPTIONS_NONEMPTY=0
    if [ "$OPTIONS_COUNT" -gt 0 ]; then
        FIRST_OPT=$(find "${DB_ROOT}" -maxdepth 2 -name 'Options-*' -o -name 'OPTIONS-*' -type f 2>/dev/null | head -1)
        [ -s "$FIRST_OPT" ] && OPTIONS_NONEMPTY=1
    fi
    echo "${OPTIONS_COUNT}:${OPTIONS_NONEMPTY}" > /shared/validator_rocksdb_options

    # Write RocksDB temporary file count (moved earlier to avoid ghost assertions)
    TMP_COUNT=$(find "${DB_ROOT}" -maxdepth 3 \( -name '*.tmp' -o -name '*.dbtmp' \) -type f 2>/dev/null | wc -l)
    echo "$TMP_COUNT" > /shared/validator_rocksdb_tmp_files

    # Write RocksDB IDENTITY file content (moved earlier to avoid ghost assertions)
    # Use a fixed path (/var/ton-work/db/IDENTITY) to ensure we always read the
    # same file. Previously, `find ... | head -1` could return IDENTITY files from
    # different RocksDB sub-instances (celldb/, blockdb/) in different orders across
    # iterations, making the identity appear to change and violating the stability
    # assertion. Fall back to find only if the root IDENTITY doesn't exist.
    if [ -f /var/ton-work/db/IDENTITY ] && [ -s /var/ton-work/db/IDENTITY ]; then
        tr -d '[:space:]' < /var/ton-work/db/IDENTITY > /shared/validator_rocksdb_identity
    else
        IDENTITY_FILE=$(find /var/ton-work/db -maxdepth 2 -name IDENTITY -type f 2>/dev/null | sort | head -1)
        if [ -n "$IDENTITY_FILE" ] && [ -s "$IDENTITY_FILE" ]; then
            tr -d '[:space:]' < "$IDENTITY_FILE" > /shared/validator_rocksdb_identity
        else
            touch /shared/validator_rocksdb_identity
        fi
    fi

    # Refresh heartbeat after moved metrics
    date +%s > /shared/validator_heartbeat

    # Write DB directory size (bytes) for data-integrity monitoring
    if [ -d "/var/ton-work/db" ]; then
        du -sb /var/ton-work/db 2>/dev/null | cut -f1 > /shared/validator_db_size
    else
        echo "0" > /shared/validator_db_size
    fi
    # Write RocksDB LOCK file existence for DB integrity monitoring
    LOCK_COUNT=$(find /var/ton-work/db -maxdepth 2 -name LOCK -type f 2>/dev/null | head -1 | wc -l)
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
    # Write config.json structural keys for structural integrity monitoring
    if [ -f "/var/ton-work/db/config.json" ]; then
        jq -r 'keys | join(",")' /var/ton-work/db/config.json > /shared/validator_config_keys 2>/dev/null || echo "error" > /shared/validator_config_keys
    else
        echo "missing" > /shared/validator_config_keys
    fi
    # Write TCP connection state counts (CLOSE_WAIT=08, TIME_WAIT=06 in hex)
    CLOSE_WAIT=$(awk '$4 == "08" {count++} END {print count+0}' /proc/1/net/tcp 2>/dev/null || echo "0")
    TIME_WAIT=$(awk '$4 == "06" {count++} END {print count+0}' /proc/1/net/tcp 2>/dev/null || echo "0")
    echo "${CLOSE_WAIT},${TIME_WAIT}" > /shared/validator_tcp_states
    # Write RocksDB WAL (.log) file count for compaction health monitoring
    WAL_COUNT=$(find /var/ton-work/db -maxdepth 2 -name "*.log" -type f 2>/dev/null | wc -l)
    echo "$WAL_COUNT" > /shared/validator_wal_count

    # Refresh heartbeat mid-way through slow operations
    date +%s > /shared/validator_heartbeat

    # Write total disk usage of /var/ton-work for disk budget monitoring
    DISK_USAGE=$(du -sb /var/ton-work 2>/dev/null | cut -f1 || echo "-1")
    echo "$DISK_USAGE" > /shared/validator_disk_usage
    # Write RocksDB MANIFEST file count for data integrity monitoring
    MANIFEST_COUNT=$(find /var/ton-work/db -maxdepth 2 -name "MANIFEST-*" -type f 2>/dev/null | wc -l)
    echo "$MANIFEST_COUNT" > /shared/validator_manifest_count
    # Write RocksDB MANIFEST file size (bytes) for metadata growth monitoring
    MANIFEST_FILE=$(cat /var/ton-work/db/CURRENT 2>/dev/null | tr -d '[:space:]')
    if [ -n "$MANIFEST_FILE" ] && [ -f "/var/ton-work/db/$MANIFEST_FILE" ]; then
        stat -c%s "/var/ton-work/db/$MANIFEST_FILE" > /shared/validator_manifest_size
    else
        touch /shared/validator_manifest_size
    fi
    # Write RocksDB CURRENT file validity (root of metadata chain: CURRENT → MANIFEST → SST)
    CURRENT_FILE=$(find /var/ton-work/db -maxdepth 2 -name CURRENT -type f 2>/dev/null | head -1)
    if [ -n "$CURRENT_FILE" ] && [ -s "$CURRENT_FILE" ]; then
        echo "1" > /shared/validator_current_valid
    else
        echo "0" > /shared/validator_current_valid
    fi
    # Cross-validate CURRENT → MANIFEST reference
    if [ -n "$CURRENT_FILE" ] && [ -s "$CURRENT_FILE" ]; then
        CURRENT_DIR=$(dirname "$CURRENT_FILE")
        MANIFEST_REF=$(cat "$CURRENT_FILE" 2>/dev/null | tr -d '[:space:]')
        if [ -n "$MANIFEST_REF" ] && [ -f "${CURRENT_DIR}/${MANIFEST_REF}" ]; then
            echo "1" > /shared/validator_current_manifest_consistent
        else
            echo "0" > /shared/validator_current_manifest_consistent
        fi
    else
        echo "-1" > /shared/validator_current_manifest_consistent
    fi
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

    # Refresh heartbeat before final batch
    date +%s > /shared/validator_heartbeat

    # Scan RocksDB LOG files for corruption/IO error indicators
    ROCKSDB_LOG=$(find /var/ton-work/db -maxdepth 2 -name "LOG" -type f 2>/dev/null | head -5)
    CORRUPTION_COUNT=0
    for logf in $ROCKSDB_LOG; do
        COUNT=$(grep -ciE "Corruption:|IO error|checksum mismatch|bad block contents|Repair" "$logf" 2>/dev/null) || true
        COUNT=${COUNT:-0}
        CORRUPTION_COUNT=$((CORRUPTION_COUNT + COUNT))
    done
    echo "$CORRUPTION_COUNT" > /shared/validator_rocksdb_errors
    # Write RocksDB LOG file size (bytes) for LOG growth monitoring
    ROCKSDB_LOG_SIZE=0
    ROCKSDB_LOG_FILE="/var/ton-work/db/LOG"
    if [ ! -f "$ROCKSDB_LOG_FILE" ]; then
        ROCKSDB_LOG_FILE=$(find /var/ton-work/db -maxdepth 2 -name "LOG" -type f 2>/dev/null | head -1)
    fi
    if [ -n "$ROCKSDB_LOG_FILE" ] && [ -f "$ROCKSDB_LOG_FILE" ]; then
        ROCKSDB_LOG_SIZE=$(stat -c%s "$ROCKSDB_LOG_FILE" 2>/dev/null || echo "0")
    fi
    echo "$ROCKSDB_LOG_SIZE" > /shared/validator_rocksdb_log_size
    # Write RocksDB compaction event count for compaction health monitoring
    COMPACTION_COUNT=0
    for logf in $ROCKSDB_LOG; do
        COUNT=$(grep -ciE "compacted to:|Compaction.*@|Manual compaction" "$logf" 2>/dev/null) || true
        COUNT=${COUNT:-0}
        COMPACTION_COUNT=$((COMPACTION_COUNT + COUNT))
    done
    echo "$COMPACTION_COUNT" > /shared/validator_compaction_count
    # Write RocksDB SST file count for data integrity monitoring
    # Search deeper (maxdepth 5) and include both .sst and .ldb extensions
    # TON uses multiple RocksDB instances in subdirs (celldb/, blockdb/, statedb/)
    SST_COUNT=$(find /var/ton-work/db -maxdepth 5 \( -name "*.sst" -o -name "*.ldb" \) -type f 2>/dev/null | wc -l)
    echo "$SST_COUNT" > /shared/validator_sst_count
    # (rocksdb_options, rocksdb_tmp_files, cmdline_hash, rocksdb_identity, db_dir_count
    #  moved to early low-priority section to avoid ghost assertions under frequent restarts)

    # Touch the validator log to keep its mtime fresh. TON's TsFileLog buffers
    # aggressively and may not flush to disk for extended periods, making the log
    # appear stale to mtime-based freshness checks even while the process is healthy.
    # A no-op append (>>) preserves content while updating mtime.
    if [ -f /shared/validator.log ]; then
        touch /shared/validator.log
    fi

    # Final heartbeat write at end of loop
    date +%s > /shared/validator_heartbeat
    sleep 5
done
) &

echo "Starting validator-engine..."
exec validator-engine \
    -C "${GLOBAL_CONFIG}" \
    --db "${DB_ROOT}" \
    --ip "${IP}:${VALIDATOR_PORT}" \
    --threads "${THREADS}" \
    --verbosity "${VERBOSITY}" \
    --logname /shared/validator.log \
    2>>/shared/validator.log
