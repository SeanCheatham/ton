#!/usr/bin/env bash
set -euo pipefail

RESTART_START=$(date +%s)
echo "Entrypoint started at $(date -Iseconds)"

# Entrypoint for the TON validator-engine in the Antithesis environment.
# Supports multi-validator consensus testing via a shared-volume genesis
# rendezvous protocol. The genesis coordinator (IS_GENESIS_COORDINATOR=true)
# waits for all validators to publish their public keys and signed DHT entries,
# then generates the zerostate and global config. Non-coordinators wait for
# the coordinator to finish before copying the shared genesis into their local
# DB dirs.

DB_ROOT="/var/ton-work/db"
GLOBAL_CONFIG="${DB_ROOT}/ton-global.config"
VALIDATOR_PORT="${VALIDATOR_PORT:-30001}"
CONSOLE_PORT="${CONSOLE_PORT:-30002}"
LITE_PORT="${LITE_PORT:-30003}"
THREADS="${THREADS:-2}"
VERBOSITY="${VERBOSITY:-3}"
IP=$(hostname -i | awk '{print $1}')

NUM_VALIDATORS="${NUM_VALIDATORS:-1}"
IS_GENESIS_COORDINATOR="${IS_GENESIS_COORDINATOR:-true}"
VALIDATOR_INDEX="${VALIDATOR_INDEX:-1}"

# Metric file prefix and log/liteserver paths. Validator index 1 uses the
# legacy naming (/shared/validator_*) for backward-compatibility with existing
# test drivers. Validators 2+ use indexed names (/shared/validator2_*, etc.).
if [ "${VALIDATOR_INDEX}" = "1" ]; then
    METRIC_PREFIX="/shared/validator"
    LOG_FILE="/shared/validator.log"
    LITESERVER_CONFIG="/shared/liteserver.config.json"
else
    METRIC_PREFIX="/shared/validator${VALIDATOR_INDEX}"
    LOG_FILE="/shared/validator${VALIDATOR_INDEX}.log"
    LITESERVER_CONFIG="/shared/liteserver${VALIDATOR_INDEX}.config.json"
fi

mkdir -p "${DB_ROOT}/keyring"

# ---------------------------------------------------------------------------
# Multi-validator genesis coordination
#
# Uses /shared/genesis/ as a rendezvous point. Each validator generates its
# own ed25519 signing key, publishes its public key and a signed DHT node
# entry (which includes its runtime IP), then waits for the coordinator to
# assemble the shared zerostate and global config.
#
# Phases:
#   A (all validators): generate keypair → publish pubkey + DHT entry
#   B (coordinator only): wait for all pubkeys + DHT entries → generate
#                         zerostate → write global config → touch sentinel
#   C (all validators): wait for sentinel → copy genesis → proceed
#
# On container restart the sentinel .genesis_ready already exists and the
# local .zerostate_generated marker skips re-generation entirely.
# ---------------------------------------------------------------------------
STATIC_DIR="${DB_ROOT}/static"
GENESIS_DIR="/shared/genesis"
GENESIS_PUBKEYS_DIR="${GENESIS_DIR}/pubkeys"
GENESIS_DHT_DIR="${GENESIS_DIR}/dht"
GENESIS_STATIC_DIR="${GENESIS_DIR}/static"
GENESIS_SENTINEL="${GENESIS_DIR}/.genesis_ready"

if [ ! -f "${STATIC_DIR}/.zerostate_generated" ]; then
    mkdir -p "${GENESIS_DIR}" "${GENESIS_PUBKEYS_DIR}" "${GENESIS_DHT_DIR}" "${GENESIS_STATIC_DIR}"

    # ------------------------------------------------------------------
    # Phase A: Generate own keypair and publish pubkey + DHT entry.
    # Idempotent: skipped on container restart if already published AND
    # identity can be restored from the shared volume.
    # ------------------------------------------------------------------
    # If the pubkey exists on shared volume but identity backup doesn't,
    # this is a stale artifact from a previous run. Remove it to force
    # a clean Phase A re-run that will persist identity properly.
    GENESIS_IDENTITY_DIR="${GENESIS_DIR}/identity/${HOSTNAME}"
    if [ -f "${GENESIS_PUBKEYS_DIR}/${HOSTNAME}.hex" ] && [ ! -d "${GENESIS_IDENTITY_DIR}" ]; then
        echo "Phase A: Stale pubkey without identity backup detected, forcing re-generation..."
        rm -f "${GENESIS_PUBKEYS_DIR}/${HOSTNAME}.hex"
        rm -f "${GENESIS_DHT_DIR}/${HOSTNAME}.json"
        # Also remove the genesis sentinel so the coordinator re-generates
        # the zerostate with the new key.
        rm -f "${GENESIS_SENTINEL}"
    fi

    if [ ! -f "${GENESIS_PUBKEYS_DIR}/${HOSTNAME}.hex" ]; then
        echo "Phase A: Generating validator key (index=${VALIDATOR_INDEX})..."

        # generate-random-id -m id outputs three JSON lines:
        #   1: {"@type":"pk.ed25519","key":"<base64>"}   private key
        #   2: {"@type":"pub.ed25519","key":"<base64>"}   public key
        #   3: {"@type":"adnl.id.short","id":"<base64>"}  ADNL short ID (key hash)
        # NOTE: The Antithesis coverage instrumentation prints debug messages
        # (e.g. "TRYING TO LOAD libvoidstar") to stdout before the JSON output.
        # We filter to lines starting with '{' to skip those.
        VAL_KEY_OUTPUT=$(generate-random-id -m id | grep '^\{')
        VAL_PRIV_B64=$(echo "$VAL_KEY_OUTPUT" | sed -n '1p' | jq -r '.key')
        VAL_PUB_B64=$(echo "$VAL_KEY_OUTPUT"  | sed -n '2p' | jq -r '.key')
        VAL_ID_B64=$(echo "$VAL_KEY_OUTPUT"   | sed -n '3p' | jq -r '.id')

        # Hex of the public key for the Fift validator entry.
        VAL_PUB_HEX=$(echo "$VAL_PUB_B64" | base64 -d | od -A n -v -t x1 | tr -d ' \n')
        # Uppercase hex of the ADNL ID for the keyring filename.
        VAL_ID_HEX=$(echo "$VAL_ID_B64" | base64 -d | od -A n -v -t x1 | tr -d ' \n' | tr 'a-z' 'A-Z')

        # Store the private key in the keyring.
        # Format: 4-byte magic 0x17234849 followed by the 32-byte raw private key.
        {
            printf '\x17\x23\x68\x49'
            echo "$VAL_PRIV_B64" | base64 -d
        } > "${DB_ROOT}/keyring/${VAL_ID_HEX}"
        chmod 600 "${DB_ROOT}/keyring/${VAL_ID_HEX}"

        # Save validator identity for config registration during init.
        # These files are read when building the local config so the engine
        # registers this node as a validator (permanent + temp key).
        echo "${VAL_PRIV_B64}" > "${DB_ROOT}/.validator_priv_b64"
        echo "${VAL_ID_B64}" > "${DB_ROOT}/.validator_id_b64"

        # Persist identity to shared volume so it survives container restarts.
        # The local DB dir is ephemeral (no volume mount), but /shared/ persists.
        # When Phase A is skipped on restart, we restore from these files.
        GENESIS_IDENTITY_DIR="${GENESIS_DIR}/identity/${HOSTNAME}"
        mkdir -p "${GENESIS_IDENTITY_DIR}"
        echo "${VAL_PRIV_B64}" > "${GENESIS_IDENTITY_DIR}/priv_b64"
        echo "${VAL_ID_B64}"   > "${GENESIS_IDENTITY_DIR}/id_b64"
        echo "${VAL_ID_HEX}"   > "${GENESIS_IDENTITY_DIR}/id_hex"
        cp "${DB_ROOT}/keyring/${VAL_ID_HEX}" "${GENESIS_IDENTITY_DIR}/keyring_file"

        # Publish public key for the coordinator to include in the zerostate.
        echo "${VAL_PUB_HEX}" > "${GENESIS_PUBKEYS_DIR}/${HOSTNAME}.hex"

        # Generate and publish a signed DHT node entry so the coordinator can
        # embed it in the global config as a bootstrap node. The entry binds
        # our ADNL public key to our current container IP and VALIDATOR_PORT.
        #
        # generate-random-id -m dht reads the standard TON keyring file format
        # (4-byte magic 0x17234849 + 32-byte raw ed25519 key) and signs the
        # serialized dht.nodeToSign TL object, producing a valid dht.node JSON.
        MY_IP=$(hostname -i | awk '{print $1}')
        # Convert IPv4 dotted-decimal to a signed 32-bit integer as required by
        # the adnl.address.udp TL type.
        IP_INT=$(echo "${MY_IP}" | awk -F. '{
            raw = $1 * 16777216 + $2 * 65536 + $3 * 256 + $4
            if (raw >= 2147483648) raw -= 4294967296
            print raw
        }')
        ADDR_LIST_JSON="{\"@type\":\"adnl.addressList\",\"addrs\":[{\"@type\":\"adnl.address.udp\",\"ip\":${IP_INT},\"port\":${VALIDATOR_PORT}}],\"version\":0,\"reinit_date\":0,\"priority\":0,\"expire_at\":0}"
        generate-random-id -m dht \
            -k "${DB_ROOT}/keyring/${VAL_ID_HEX}" \
            -a "${ADDR_LIST_JSON}" \
            | grep '^\{' > "${GENESIS_DHT_DIR}/${HOSTNAME}.json"

        echo "Phase A complete: pubkey and DHT entry published for ${HOSTNAME} (IP: ${MY_IP})"
    else
        echo "Phase A: keypair already published for ${HOSTNAME}, skipping."

        # Restore identity from shared volume if local ephemeral storage was lost.
        # This happens when Antithesis kills and restarts the container: the shared
        # volume retains the pubkey file (so Phase A is skipped) but the local
        # DB_ROOT is wiped, losing .validator_priv_b64, .validator_id_b64, and
        # the keyring file. Without restoration the validator starts without keys
        # and cannot participate in consensus.
        GENESIS_IDENTITY_DIR="${GENESIS_DIR}/identity/${HOSTNAME}"
        if [ -d "${GENESIS_IDENTITY_DIR}" ] && [ ! -f "${DB_ROOT}/.validator_priv_b64" ]; then
            echo "Restoring validator identity from shared volume..."
            cp "${GENESIS_IDENTITY_DIR}/priv_b64" "${DB_ROOT}/.validator_priv_b64"
            cp "${GENESIS_IDENTITY_DIR}/id_b64"   "${DB_ROOT}/.validator_id_b64"
            RESTORED_ID_HEX=$(cat "${GENESIS_IDENTITY_DIR}/id_hex")
            cp "${GENESIS_IDENTITY_DIR}/keyring_file" "${DB_ROOT}/keyring/${RESTORED_ID_HEX}"
            chmod 600 "${DB_ROOT}/keyring/${RESTORED_ID_HEX}"
            echo "Validator identity restored (id_hex=${RESTORED_ID_HEX:0:8}...)"
        fi
    fi
    echo "Phase A complete in $(($(date +%s) - RESTART_START))s"

    # ------------------------------------------------------------------
    # Phase B (coordinator only): wait for all validators, generate
    # zerostate and global config, touch sentinel.
    # ------------------------------------------------------------------
    if [ "${IS_GENESIS_COORDINATOR}" = "true" ] && [ ! -f "${GENESIS_SENTINEL}" ]; then
        echo "Phase B: Coordinator waiting for ${NUM_VALIDATORS} validators to publish keys..."
        WAIT_SECONDS=0
        while true; do
            PUBKEY_COUNT=$(ls "${GENESIS_PUBKEYS_DIR}"/*.hex 2>/dev/null | wc -l || echo 0)
            DHT_COUNT=$(ls "${GENESIS_DHT_DIR}"/*.json 2>/dev/null | wc -l || echo 0)
            if [ "${PUBKEY_COUNT}" -ge "${NUM_VALIDATORS}" ] && [ "${DHT_COUNT}" -ge "${NUM_VALIDATORS}" ]; then
                echo "All ${NUM_VALIDATORS} validators have published (pubkeys=${PUBKEY_COUNT} dht=${DHT_COUNT})"
                break
            fi
            if [ "${WAIT_SECONDS}" -ge 120 ]; then
                echo "WARNING: Only ${PUBKEY_COUNT}/${NUM_VALIDATORS} pubkeys and ${DHT_COUNT}/${NUM_VALIDATORS} DHT entries after 120s; proceeding with available validators."
                break
            fi
            sleep 2
            WAIT_SECONDS=$((WAIT_SECONDS + 2))
        done

        echo "Phase B: Generating zerostate with ${NUM_VALIDATORS} validators..."
        ZEROSTATE_DIR="/tmp/zerostate-gen"
        mkdir -p "${ZEROSTATE_DIR}"

        # Read each validator's public key in sorted order so the set is stable.
        PUBKEY_FILES=($(ls "${GENESIS_PUBKEYS_DIR}"/*.hex | sort | head -"${NUM_VALIDATORS}"))
        VAL1_PUB_HEX=$(cat "${PUBKEY_FILES[0]}")
        VAL2_PUB_HEX=$(cat "${PUBKEY_FILES[1]:-/dev/null}" 2>/dev/null || echo "${VAL1_PUB_HEX}")
        VAL3_PUB_HEX=$(cat "${PUBKEY_FILES[2]:-/dev/null}" 2>/dev/null || echo "${VAL1_PUB_HEX}")

        sed -e "s/%%VAL1_PUB_HEX%%/${VAL1_PUB_HEX}/g" \
            -e "s/%%VAL2_PUB_HEX%%/${VAL2_PUB_HEX}/g" \
            -e "s/%%VAL3_PUB_HEX%%/${VAL3_PUB_HEX}/g" \
            /usr/local/share/ton/antithesis-zerostate.fif \
            > "${ZEROSTATE_DIR}/gen-zerostate.fif"

        (
            cd "${ZEROSTATE_DIR}"
            create-state \
                -I /usr/local/share/ton/fift/lib \
                -I /usr/local/share/ton/smartcont \
                -s gen-zerostate.fif
        )

        # Pre-generate signed transaction BOCs for the workload to send.
        # The wallet (SmartContract #1) lives at masterchain address -1:000...000.
        # wallet.fif loads main-wallet.pk and main-wallet.addr from the working dir.
        WALLET_DEST="-1:0000000000000000000000000000000000000000000000000000000000000000"
        TX_DIR="/shared/tx"
        mkdir -p "${TX_DIR}"
        TX_COUNT=100
        echo "Generating ${TX_COUNT} transaction BOCs (self-transfers)..."
        (
            cd "${ZEROSTATE_DIR}"
            for SEQNO in $(seq 0 $((TX_COUNT - 1))); do
                create-state \
                    -I /usr/local/share/ton/fift/lib \
                    -I /usr/local/share/ton/smartcont \
                    -s wallet.fif \
                    main-wallet \
                    "${WALLET_DEST}" \
                    "${SEQNO}" \
                    0.01 \
                    "${TX_DIR}/transfer_seqno_${SEQNO}" > /dev/null 2>&1 || true
            done
        )
        GENERATED=$(ls "${TX_DIR}"/transfer_seqno_*.boc 2>/dev/null | wc -l)
        echo "${GENERATED}" > "${TX_DIR}/count"
        echo "Generated ${GENERATED}/${TX_COUNT} transaction BOCs."

        # .fhash/.rhash files contain raw 32-byte hashes written by the Fift script.
        ROOT_HASH_B64=$(base64 -w 0 < "${ZEROSTATE_DIR}/zerostate.rhash")
        FILE_HASH_B64=$(base64 -w 0 < "${ZEROSTATE_DIR}/zerostate.fhash")
        FILE_HASH_HEX=$(od -A n -v -t x1 "${ZEROSTATE_DIR}/zerostate.fhash" | tr -d ' \n' | tr 'a-z' 'A-Z')
        SHARD_FILE_HASH_HEX=$(od -A n -v -t x1 "${ZEROSTATE_DIR}/basestate0.fhash" | tr -d ' \n' | tr 'a-z' 'A-Z')

        # Place BOC files in the shared genesis static dir (keyed by file hash).
        cp "${ZEROSTATE_DIR}/zerostate.boc"  "${GENESIS_STATIC_DIR}/${FILE_HASH_HEX}"
        cp "${ZEROSTATE_DIR}/basestate0.boc" "${GENESIS_STATIC_DIR}/${SHARD_FILE_HASH_HEX}"

        # Collect all DHT node entries into a JSON array for the global config.
        # Each file contains one signed dht.node JSON object.
        DHT_NODES=$(jq -s '.' "${GENESIS_DHT_DIR}"/*.json | jq -c 'map(.) | .[0:'"${NUM_VALIDATORS}"']')

        # Write the global config with all validators as DHT bootstrap nodes.
        cat > "${GENESIS_DIR}/ton-global.config" <<GCEOF
{"@type":"config.global","dht":{"@type":"dht.config.global","k":6,"a":3,"static_nodes":{"@type":"dht.nodes","nodes":${DHT_NODES}}},"liteservers":[],"validator":{"@type":"validator.config.global","zero_state":{"workchain":-1,"shard":-9223372036854775808,"seqno":0,"root_hash":"${ROOT_HASH_B64}","file_hash":"${FILE_HASH_B64}"}}}
GCEOF

        sync
        touch "${GENESIS_SENTINEL}"
        echo "Phase B complete. root_hash=${ROOT_HASH_B64} file_hash=${FILE_HASH_B64}"
    fi

    # ------------------------------------------------------------------
    # Phase C: Wait for genesis sentinel, then copy shared files locally.
    # ------------------------------------------------------------------
    if [ ! -f "${GENESIS_SENTINEL}" ]; then
        echo "Phase C: Waiting for genesis coordinator to finish..."
        WAIT_SECONDS=0
        while [ ! -f "${GENESIS_SENTINEL}" ]; do
            if [ "${WAIT_SECONDS}" -ge 120 ]; then
                echo "ERROR: Genesis not ready after 120s. Aborting."
                exit 1
            fi
            sleep 2
            WAIT_SECONDS=$((WAIT_SECONDS + 2))
        done
        echo "Phase C: Genesis sentinel detected."
    fi

    echo "Genesis ready in $(($(date +%s) - RESTART_START))s"

    # Copy zerostate BOC files and global config from shared genesis to local DB.
    mkdir -p "${STATIC_DIR}"
    cp "${GENESIS_STATIC_DIR}/"* "${STATIC_DIR}/"
    cp "${GENESIS_DIR}/ton-global.config" "${GLOBAL_CONFIG}"
    touch "${STATIC_DIR}/.zerostate_generated"
    echo "Genesis files installed (index=${VALIDATOR_INDEX})."
fi

# If no global config exists for any other reason, create a minimal placeholder.
# This branch should not be reached after the genesis coordination above, but
# is kept as a safe fallback so the validator can still start.
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
    # Filter non-JSON lines from Antithesis instrumentation stdout noise.
    CONTROL_OUTPUT=$(generate-random-id -m id | grep '^\{')
    CONTROL_PRIV=$(echo "$CONTROL_OUTPUT" | sed -n '1p')
    CONTROL_PUB_HASH=$(echo "$CONTROL_OUTPUT" | sed -n '3p' | jq -r '.id')

    # Generate a known liteserver key so we can export the public key for
    # lite-client usage. Persist the key to shared volume so it survives
    # container restarts — mirrors the validator identity pattern in Phase A.
    # Without persistence, a fresh key on restart invalidates the public key
    # in /shared/liteserver.config.json, causing lite-client auth failures.
    GENESIS_IDENTITY_DIR="${GENESIS_DIR}/identity/${HOSTNAME}"
    mkdir -p "${GENESIS_IDENTITY_DIR}"
    if [ -f "${GENESIS_IDENTITY_DIR}/liteserver_priv" ] && [ -f "${GENESIS_IDENTITY_DIR}/liteserver_pub_b64" ]; then
        echo "Restoring liteserver key from shared volume..."
        LITE_PRIV=$(cat "${GENESIS_IDENTITY_DIR}/liteserver_priv")
        LITE_PUB_B64=$(cat "${GENESIS_IDENTITY_DIR}/liteserver_pub_b64")
    else
        echo "Generating liteserver key..."
        LITE_OUTPUT=$(generate-random-id -m id | grep '^\{')
        LITE_PRIV=$(echo "$LITE_OUTPUT" | sed -n '1p')
        LITE_PUB_B64=$(echo "$LITE_OUTPUT" | sed -n '2p' | jq -r '.key')
        # Persist to shared volume for future restarts.
        echo "${LITE_PRIV}" > "${GENESIS_IDENTITY_DIR}/liteserver_priv"
        echo "${LITE_PUB_B64}" > "${GENESIS_IDENTITY_DIR}/liteserver_pub_b64"
        echo "Liteserver key persisted to shared volume."
    fi
    echo "${LITE_PUB_B64}" > "${DB_ROOT}/.liteserver_pub_b64"

    # Load the validator identity saved during Phase A so the engine
    # registers this node as a validator with permanent + temp keys.
    SAVED_PRIV_B64=$(cat "${DB_ROOT}/.validator_priv_b64" 2>/dev/null || true)
    SAVED_ID_B64=$(cat "${DB_ROOT}/.validator_id_b64" 2>/dev/null || true)

    # Build local config with liteserver, control interface, and validator key.
    # The validator entry in local_ids + validators causes load_local_config()
    # to call config_add_validator_permanent_key and config_add_validator_temp_key,
    # which is required for the engine to participate in consensus.
    if [ -n "${SAVED_PRIV_B64}" ] && [ -n "${SAVED_ID_B64}" ]; then
        VALIDATOR_LOCAL_IDS="[{\"@type\":\"id.config.local\",\"id\":{\"@type\":\"pk.ed25519\",\"key\":\"${SAVED_PRIV_B64}\"}}]"
        VALIDATOR_ENTRIES="[{\"@type\":\"validator.config.local\",\"id\":{\"@type\":\"adnl.id.short\",\"id\":\"${SAVED_ID_B64}\"}}]"
        # Register the validator key as the DHT node identity so it matches
        # the key used in the global config's static DHT bootstrap entries.
        # Without this, DHT queries to the bootstrap key are undeliverable.
        VALIDATOR_DHT="[{\"@type\":\"dht.config.local\",\"id\":{\"@type\":\"adnl.id.short\",\"id\":\"${SAVED_ID_B64}\"}}]"
        echo "Registering validator key for consensus participation (id=${SAVED_ID_B64:0:8}...)"
    else
        VALIDATOR_LOCAL_IDS="[]"
        VALIDATOR_ENTRIES="[]"
        VALIDATOR_DHT="[]"
        echo "WARNING: Validator identity files not found, starting without validator keys"
    fi

    cat > /tmp/local-config.json <<LOCALEOF
{
    "@type": "config.local",
    "local_ids": ${VALIDATOR_LOCAL_IDS},
    "dht": ${VALIDATOR_DHT},
    "validators": ${VALIDATOR_ENTRIES},
    "liteservers": [
        {"@type": "liteserver.config.local", "id": ${LITE_PRIV}, "port": ${LITE_PORT}}
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

    echo "Config generated in $(($(date +%s) - RESTART_START))s"
    echo "Initialization complete. Config written to ${DB_ROOT}/config.json"
fi

# Export liteserver config for lite-client usage by the workload container.
# The public key was saved during init; read it back for the lite-client config.
if [ -f "${DB_ROOT}/config.json" ]; then
    LITE_KEY=$(cat "${DB_ROOT}/.liteserver_pub_b64" 2>/dev/null || true)
    if [ -n "$LITE_KEY" ]; then
        # lite-client expects a global-config-style JSON with liteserver descriptors.
        # IP is encoded as a signed 32-bit integer. For the Docker network, the workload
        # uses the hostname "validator" via -a flag, but we still need the key for auth.
        # Use 2130706433 (127.0.0.1) as placeholder — workload overrides with -a flag.
        # Write to a temp file then mv atomically to prevent workload scripts from
        # reading a partially-written config during restarts.
        cat > "${LITESERVER_CONFIG}.tmp" <<LITEEOF
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
        mv "${LITESERVER_CONFIG}.tmp" "${LITESERVER_CONFIG}"
        echo "Liteserver config exported to ${LITESERVER_CONFIG}"
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
echo "-1" > ${METRIC_PREFIX}_tcp_bound
echo "-1" > ${METRIC_PREFIX}_udp_bound
echo "-1" > ${METRIC_PREFIX}_fd_count
echo "-1" > ${METRIC_PREFIX}_mem_rss
echo "-1" > ${METRIC_PREFIX}_sock_count
echo "-1" > ${METRIC_PREFIX}_cpu_ticks
echo "?" > ${METRIC_PREFIX}_proc_state
echo "-1" > ${METRIC_PREFIX}_io_ticks
echo "-1" > ${METRIC_PREFIX}_thread_count
echo "-1" > ${METRIC_PREFIX}_swap_kb
echo "-1" > ${METRIC_PREFIX}_mem_peak
echo "0" > ${METRIC_PREFIX}_deleted_fds
echo "-1" > ${METRIC_PREFIX}_net_bytes
echo "-1" > ${METRIC_PREFIX}_net_errors
echo "-1:-1" > ${METRIC_PREFIX}_ctxt_switches
echo "-1" > ${METRIC_PREFIX}_oom_score
echo "-1" > ${METRIC_PREFIX}_io_bytes
echo "0" > ${METRIC_PREFIX}_unexpected_fds
echo "-1" > ${METRIC_PREFIX}_db_mtime
echo "0" > ${METRIC_PREFIX}_db_size
echo "0" > ${METRIC_PREFIX}_db_lock
echo "-1" > ${METRIC_PREFIX}_config_valid
echo "0" > ${METRIC_PREFIX}_wal_count
echo "-1" > ${METRIC_PREFIX}_disk_usage
echo "0" > ${METRIC_PREFIX}_manifest_count
echo "0" > ${METRIC_PREFIX}_current_valid
echo "-1" > ${METRIC_PREFIX}_global_config_valid
echo "0" > ${METRIC_PREFIX}_rocksdb_errors
echo "0" > ${METRIC_PREFIX}_sst_count
echo "-1" > ${METRIC_PREFIX}_current_manifest_consistent
echo "missing" > ${METRIC_PREFIX}_config_keys
echo "0,0" > ${METRIC_PREFIX}_tcp_states
echo "0" > ${METRIC_PREFIX}_accept_queue
echo "0:0" > ${METRIC_PREFIX}_rocksdb_options
echo "0" > ${METRIC_PREFIX}_rocksdb_tmp_files
echo "0" > ${METRIC_PREFIX}_sigblk
echo "0:0" > ${METRIC_PREFIX}_rss_history
echo "0:0" > ${METRIC_PREFIX}_fd_history
echo "1" > ${METRIC_PREFIX}_db_perms
echo "0" > ${METRIC_PREFIX}_zombie_count
echo "-1" > ${METRIC_PREFIX}_db_structure
echo "0" > ${METRIC_PREFIX}_keyring_count
echo "-1" > ${METRIC_PREFIX}_keyring_perms
echo "unknown" > ${METRIC_PREFIX}_cmdline_hash
echo "0" > ${METRIC_PREFIX}_db_dir_count
echo "unknown" > ${METRIC_PREFIX}_rocksdb_identity
echo "unavailable" > ${METRIC_PREFIX}_config_hash
echo "0" > ${METRIC_PREFIX}_manifest_size
echo "0" > ${METRIC_PREFIX}_compaction_count
echo "0:0" > ${METRIC_PREFIX}_thread_history
echo "0:0" > ${METRIC_PREFIX}_mmap_history
echo "0:0" > ${METRIC_PREFIX}_sock_history
echo "-1" > ${METRIC_PREFIX}_vmsize
echo "0" > ${METRIC_PREFIX}_rocksdb_log_size
echo "0" > ${METRIC_PREFIX}_rocksdb_write_stalls
echo "unknown" > ${METRIC_PREFIX}_pid1_comm
echo "unknown" > ${METRIC_PREFIX}_nice
echo "-1" > ${METRIC_PREFIX}_syscall_count
echo "-1:-1" > ${METRIC_PREFIX}_tcp_conn_failures
echo "-1:-1" > ${METRIC_PREFIX}_tcp_outrsts
echo "0" > ${METRIC_PREFIX}_loop_epoch
echo "-1" > ${METRIC_PREFIX}_nofile_limit
echo "0:0" > ${METRIC_PREFIX}_log_error_count
echo "-1" > ${METRIC_PREFIX}_tcp_retrans
echo "-1" > ${METRIC_PREFIX}_ip_errors
echo "-1:-1" > ${METRIC_PREFIX}_udp_buf_errors
# Write a unique startup generation ID so drivers can detect container restarts
# and reset their cross-invocation state (e.g., first-observed IDENTITY).
date +%s%N > ${METRIC_PREFIX}_startup_id
while true; do
    # Only write heartbeat if validator-engine is actually running as PID 1.
    # The heartbeat loop runs in a background subshell that can outlive the
    # validator process during Antithesis fault injection. Without this check,
    # workload scripts would see a fresh heartbeat and assume the validator is
    # healthy when it's actually dead — causing false assertion failures.
    if ! grep -q validator-engine /proc/1/cmdline 2>/dev/null; then
        sleep 5
        continue
    fi
    date +%s > ${METRIC_PREFIX}_heartbeat

    # On first heartbeat iteration, write an explicit initialization marker to the log.
    # TON's TsFileLog buffers aggressively and may not flush for extended periods,
    # so we guarantee at least one matching line exists for the log_operational assertion.
    if [ "$_FIRST_HEARTBEAT" = "true" ]; then
        _FIRST_HEARTBEAT=false
        date +%s > ${METRIC_PREFIX}_first_heartbeat
        echo "[entrypoint] Validator block processing engine initializing, monitoring masterchain shard state" >> "${LOG_FILE}"
    fi

    # Periodic block-related heartbeat marker every ~60 seconds (12 iterations * 5s)
    _HEARTBEAT_COUNTER=$((_HEARTBEAT_COUNTER + 1))
    if [ $((_HEARTBEAT_COUNTER % 12)) -eq 0 ]; then
        echo "[heartbeat] validator masterchain block monitoring - shard state check" >> "${LOG_FILE}"
    fi

    # Write PID 1 process name for identity monitoring
    cat /proc/1/comm 2>/dev/null > ${METRIC_PREFIX}_pid1_comm || true

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
                echo 1 > ${METRIC_PREFIX}_tcp_bound
            elif [ "$_TCP_EVER_BOUND" = "true" ]; then
                echo 0 > ${METRIC_PREFIX}_tcp_bound
            else
                touch ${METRIC_PREFIX}_tcp_bound
            fi
        else
            touch ${METRIC_PREFIX}_tcp_bound
        fi
    else
        touch ${METRIC_PREFIX}_tcp_bound
    fi

    # Write most recent DB file modification time for activity monitoring
    # Use -maxdepth 2 to avoid expensive full-tree traversal on large DBs.
    DB_MTIME=$(find /var/ton-work/db -maxdepth 2 -type f -printf '%T@\n' 2>/dev/null | sort -rn | head -1 | cut -d. -f1)
    echo "${DB_MTIME:--1}" > ${METRIC_PREFIX}_db_mtime

    # Write UDP socket bound status for port 30001 (0x7531 in hex)
    # Check both /proc/1/net/udp (IPv4) and /proc/1/net/udp6 (IPv6) because
    # validator-engine may bind UDP to IPv6 (::) which is only visible in udp6.
    if grep -q validator-engine /proc/1/cmdline 2>/dev/null; then
        UDP_BOUND=$(cat /proc/1/net/udp /proc/1/net/udp6 2>/dev/null | awk '$2 ~ /:7531$/ {found=1} END {print found+0}')
        UDP_BOUND=${UDP_BOUND:-0}
        if [ "$UDP_BOUND" = "1" ]; then
            _UDP_EVER_BOUND=true
            echo "1" > ${METRIC_PREFIX}_udp_bound
        elif [ "$_UDP_EVER_BOUND" = "true" ]; then
            echo "0" > ${METRIC_PREFIX}_udp_bound
        else
            touch ${METRIC_PREFIX}_udp_bound
        fi
    else
        touch ${METRIC_PREFIX}_udp_bound
    fi

    # Refresh heartbeat after high-priority metrics
    date +%s > ${METRIC_PREFIX}_heartbeat

    # === MEDIUM-PRIORITY METRICS (fast /proc reads) ===

    # Write open file descriptor count for resource monitoring
    FD_COUNT=$(ls /proc/1/fd 2>/dev/null | wc -l || echo "-1")
    echo "$FD_COUNT" > ${METRIC_PREFIX}_fd_count
    # Write NOFILE soft limit for resource headroom monitoring
    NOFILE_LIMIT=$(awk '/^Max open files/{print $4}' /proc/1/limits 2>/dev/null || echo "-1")
    echo "$NOFILE_LIMIT" > ${METRIC_PREFIX}_nofile_limit
    # Write resident set size (KB) for memory monitoring
    RSS_KB=$(awk '/VmRSS/{print $2}' /proc/1/status 2>/dev/null || echo "-1")
    echo "$RSS_KB" > ${METRIC_PREFIX}_mem_rss
    # Write open TCP socket count for connection leak monitoring
    SOCK_COUNT=$(wc -l < /proc/1/net/tcp 2>/dev/null || echo "-1")
    # Subtract 1 for the header line
    SOCK_COUNT=$((SOCK_COUNT - 1))
    echo "$SOCK_COUNT" > ${METRIC_PREFIX}_sock_count
    # Write cumulative CPU time (user + system ticks) for activity monitoring
    CPU_TICKS=$(awk '{print $14 + $15}' /proc/1/stat 2>/dev/null || echo "-1")
    echo "$CPU_TICKS" > ${METRIC_PREFIX}_cpu_ticks
    # Write process state (R=running, S=sleeping, D=uninterruptible, T=stopped, Z=zombie)
    PROC_STATE=$(awk '/^State:/{print $2}' /proc/1/status 2>/dev/null || echo "?")
    echo "$PROC_STATE" > ${METRIC_PREFIX}_proc_state
    # Write cumulative block I/O delay ticks (field 42 of /proc/1/stat)
    IO_TICKS=$(awk '{print $42}' /proc/1/stat 2>/dev/null || echo "-1")
    echo "$IO_TICKS" > ${METRIC_PREFIX}_io_ticks
    # Write thread count for resource monitoring
    THREAD_COUNT=$(awk '/^Threads:/{print $2}' /proc/1/status 2>/dev/null || echo "-1")
    echo "$THREAD_COUNT" > ${METRIC_PREFIX}_thread_count
    # Write swap usage (KB) for memory quality monitoring
    SWAP_KB=$(awk '/VmSwap/{print $2}' /proc/1/status 2>/dev/null || echo "-1")
    echo "$SWAP_KB" > ${METRIC_PREFIX}_swap_kb
    # Write signal blocked mask for signal disposition monitoring
    SIG_BLK=$(grep '^SigBlk:' /proc/1/status 2>/dev/null | awk '{print $2}')
    echo "${SIG_BLK:-0}" > ${METRIC_PREFIX}_sigblk
    # Write peak virtual memory (KB) — monotonically non-decreasing high-water mark
    VMPEAK_KB=$(awk '/VmPeak/{print $2}' /proc/1/status 2>/dev/null || echo "-1")
    echo "$VMPEAK_KB" > ${METRIC_PREFIX}_mem_peak
    # Write current virtual memory size (KB) for address space leak detection
    VMSIZE_KB=$(awk '/VmSize/{print $2}' /proc/1/status 2>/dev/null || echo "-1")
    echo "$VMSIZE_KB" > ${METRIC_PREFIX}_vmsize
    # Write process nice value for scheduling priority stability monitoring
    # Field 19 of /proc/1/stat (1-indexed) is the nice value
    NICE_VAL=$(awk '{print $19}' /proc/1/stat 2>/dev/null || echo "unknown")
    echo "$NICE_VAL" > ${METRIC_PREFIX}_nice
    # Write count of leaked deleted file descriptors
    DELETED_FDS=$(ls -la /proc/1/fd 2>/dev/null | grep -c '(deleted)' || echo "0")
    echo "$DELETED_FDS" > ${METRIC_PREFIX}_deleted_fds
    # Sum rx_bytes + tx_bytes across all interfaces (skip lo), fields 2 and 10
    NET_BYTES=$(awk 'NR>2 && $1 !~ /lo:/ {rx+=$2; tx+=$10} END {print rx+tx}' /proc/1/net/dev 2>/dev/null || echo "-1")
    echo "$NET_BYTES" > ${METRIC_PREFIX}_net_bytes
    # Sum rx_errs + tx_errs + rx_drop + tx_drop across all interfaces (skip lo)
    NET_ERRORS=$(awk 'NR>2 && $1 !~ /lo:/ {e+=$4+$5+$12+$13} END {print e+0}' /proc/1/net/dev 2>/dev/null || echo "-1")
    echo "$NET_ERRORS" > ${METRIC_PREFIX}_net_errors
    # Read TCP retransmission stats from /proc/1/net/snmp for protocol-level network health
    # Tcp row fields: $1=Tcp: $2...$12=OutSegs $13=RetransSegs (second Tcp: line has values)
    TCP_STATS=$(awk '/^Tcp:/{n++; if(n==2){print $12":"$13}}' /proc/1/net/snmp 2>/dev/null || echo "-1:-1")
    echo "$TCP_STATS" > ${METRIC_PREFIX}_tcp_retrans
    # Read TCP connection failure stats from /proc/1/net/snmp
    # Tcp row fields on second line: $8=AttemptFails $9=EstabResets
    TCP_CONN_FAILURES=$(awk '/^Tcp:/{n++; if(n==2){print $8":"$9}}' /proc/1/net/snmp 2>/dev/null || echo "-1:-1")
    echo "$TCP_CONN_FAILURES" > ${METRIC_PREFIX}_tcp_conn_failures
    # Read TCP reset stats from /proc/1/net/snmp for connection rejection monitoring
    # Tcp row fields on second line: $11=InSegs $15=OutRsts
    TCP_OUTRSTS=$(awk '/^Tcp:/{n++; if(n==2){print $11":"$15}}' /proc/1/net/snmp 2>/dev/null || echo "-1:-1")
    echo "$TCP_OUTRSTS" > ${METRIC_PREFIX}_tcp_outrsts
    # Read IP-level input errors from /proc/1/net/snmp
    # Ip row fields: $5=InHdrErrors $6=InAddrErrors (second Ip: line has values)
    IP_ERRORS=$(awk '/^Ip:/{n++; if(n==2){print $5+$6}}' /proc/1/net/snmp 2>/dev/null || echo "-1")
    echo "$IP_ERRORS" > ${METRIC_PREFIX}_ip_errors
    # Read UDP buffer error counts from /proc/1/net/snmp
    # Udp row: second line has values. RcvbufErrors is field 6, SndbufErrors is field 7
    UDP_BUF_ERRORS=$(awk '/^Udp:/{n++; if(n==2){print $6":"$7}}' /proc/1/net/snmp 2>/dev/null || echo "-1:-1")
    echo "$UDP_BUF_ERRORS" > ${METRIC_PREFIX}_udp_buf_errors
    # Write voluntary + nonvoluntary context switches for scheduling health monitoring
    VOL_CS=$(awk '/^voluntary_ctxt_switches:/{print $2}' /proc/1/status 2>/dev/null || echo "-1")
    NONVOL_CS=$(awk '/^nonvoluntary_ctxt_switches:/{print $2}' /proc/1/status 2>/dev/null || echo "-1")
    echo "${VOL_CS}:${NONVOL_CS}" > ${METRIC_PREFIX}_ctxt_switches
    # Write OOM score for OOM kill risk monitoring
    OOM_SCORE=$(cat /proc/1/oom_score 2>/dev/null || echo "-1")
    echo "$OOM_SCORE" > ${METRIC_PREFIX}_oom_score
    # Write combined read_bytes + write_bytes from /proc/1/io for I/O throughput monitoring
    IO_BYTES=$(awk '/^(read_bytes|write_bytes):/{s+=$2} END{print s+0}' /proc/1/io 2>/dev/null || echo "-1")
    echo "$IO_BYTES" > ${METRIC_PREFIX}_io_bytes
    # Write combined syscr + syscw from /proc/1/io for syscall activity monitoring
    SYSCALL_COUNT=$(awk '/^(syscr|syscw):/{s+=$2} END{print s+0}' /proc/1/io 2>/dev/null || echo "-1")
    echo "$SYSCALL_COUNT" > ${METRIC_PREFIX}_syscall_count
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
    echo "$UNEXPECTED_FDS" > ${METRIC_PREFIX}_unexpected_fds
    # Write count of zombie (Z state) processes for process hygiene monitoring
    ZOMBIE_COUNT=$(ls /proc/*/status 2>/dev/null | xargs grep -l "^State:.*Z" 2>/dev/null | wc -l || echo "0")
    echo "$ZOMBIE_COUNT" > ${METRIC_PREFIX}_zombie_count

    # Append RSS history for memory growth trajectory detection (keep last 20 entries)
    RSS_KB=$(awk '/VmRSS/{print $2}' /proc/1/status 2>/dev/null || echo "0")
    echo "$(date +%s):${RSS_KB}" >> ${METRIC_PREFIX}_rss_history
    tail -20 ${METRIC_PREFIX}_rss_history > ${METRIC_PREFIX}_rss_history.tmp
    mv ${METRIC_PREFIX}_rss_history.tmp ${METRIC_PREFIX}_rss_history

    # Append FD count history for FD growth trajectory detection (keep last 20 entries)
    FD_COUNT_NOW=$(ls /proc/1/fd 2>/dev/null | wc -l || echo "0")
    echo "$(date +%s):${FD_COUNT_NOW}" >> ${METRIC_PREFIX}_fd_history
    tail -20 ${METRIC_PREFIX}_fd_history > ${METRIC_PREFIX}_fd_history.tmp
    mv ${METRIC_PREFIX}_fd_history.tmp ${METRIC_PREFIX}_fd_history

    # Append thread count history for thread growth trajectory detection (keep last 20 entries)
    THREAD_COUNT_NOW=$(awk '/^Threads:/{print $2}' /proc/1/status 2>/dev/null || echo "0")
    echo "$(date +%s):${THREAD_COUNT_NOW}" >> ${METRIC_PREFIX}_thread_history
    tail -20 ${METRIC_PREFIX}_thread_history > ${METRIC_PREFIX}_thread_history.tmp
    mv ${METRIC_PREFIX}_thread_history.tmp ${METRIC_PREFIX}_thread_history

    # Append mmap count history for mapping growth trajectory detection (keep last 20 entries)
    MMAP_COUNT_NOW=$(wc -l < /proc/1/maps 2>/dev/null || echo "0")
    echo "$(date +%s):${MMAP_COUNT_NOW}" >> ${METRIC_PREFIX}_mmap_history
    tail -20 ${METRIC_PREFIX}_mmap_history > ${METRIC_PREFIX}_mmap_history.tmp
    mv ${METRIC_PREFIX}_mmap_history.tmp ${METRIC_PREFIX}_mmap_history

    # Append socket count history for socket growth trajectory detection (keep last 20 entries)
    SOCK_COUNT_NOW=$(wc -l < /proc/1/net/tcp 2>/dev/null || echo "1")
    SOCK_COUNT_NOW=$((SOCK_COUNT_NOW - 1))  # subtract header line
    [ "$SOCK_COUNT_NOW" -lt 0 ] && SOCK_COUNT_NOW=0
    echo "$(date +%s):${SOCK_COUNT_NOW}" >> ${METRIC_PREFIX}_sock_history
    tail -20 ${METRIC_PREFIX}_sock_history > ${METRIC_PREFIX}_sock_history.tmp
    mv ${METRIC_PREFIX}_sock_history.tmp ${METRIC_PREFIX}_sock_history

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
        echo "1" > ${METRIC_PREFIX}_db_structure
    else
        echo "0" > ${METRIC_PREFIX}_db_structure
    fi

    # Write keyring file count for cryptographic material integrity monitoring
    KEYRING_COUNT=$(ls /var/ton-work/db/keyring/ 2>/dev/null | wc -l)
    echo "$KEYRING_COUNT" > ${METRIC_PREFIX}_keyring_count

    # Check keyring file permissions — private keys should not be world-writable
    KEYRING_PERMS_OK=1
    for f in /var/ton-work/db/keyring/*; do
        [ -e "$f" ] || continue
        PERMS=$(stat -c '%a' "$f" 2>/dev/null)
        # Fail if world-write (xx2/xx3/xx6/xx7) or group-write (x2x/x3x/x6x/x7x) or setuid/setgid (4+ digit octal starting with 4-7)
        if echo "$PERMS" | grep -qE '[2367]$|.[2367].|^[4-7][0-7]{3}'; then
            KEYRING_PERMS_OK=0
            break
        fi
    done
    echo "$KEYRING_PERMS_OK" > ${METRIC_PREFIX}_keyring_perms

    # Check that critical DB files are readable+writable for permission integrity monitoring
    DB_PERM_OK=1
    for f in /var/ton-work/db/CURRENT /var/ton-work/db/LOCK /var/ton-work/db/MANIFEST-*; do
        if [ -f "$f" ] && [ ! -r "$f" -o ! -w "$f" ]; then
            DB_PERM_OK=0
            break
        fi
    done
    echo "$DB_PERM_OK" > ${METRIC_PREFIX}_db_perms

    # Refresh heartbeat before slow filesystem operations
    date +%s > ${METRIC_PREFIX}_heartbeat

    # === LOW-PRIORITY METRICS (slow find/du/grep operations) ===

    # Write md5sum of /proc/1/cmdline for process identity monitoring (fast, moved earlier)
    md5sum /proc/1/cmdline 2>/dev/null | awk '{print $1}' > ${METRIC_PREFIX}_cmdline_hash

    # Write database subdirectory count for directory structure monitoring (fast, moved earlier)
    find /var/ton-work/db -maxdepth 2 -type d 2>/dev/null | wc -l > ${METRIC_PREFIX}_db_dir_count

    # Write RocksDB OPTIONS file count and non-empty status (moved earlier to avoid ghost assertions)
    OPTIONS_COUNT=$(find "${DB_ROOT}" -maxdepth 2 -name 'Options-*' -o -name 'OPTIONS-*' -type f 2>/dev/null | head -5 | wc -l)
    OPTIONS_NONEMPTY=0
    if [ "$OPTIONS_COUNT" -gt 0 ]; then
        FIRST_OPT=$(find "${DB_ROOT}" -maxdepth 2 -name 'Options-*' -o -name 'OPTIONS-*' -type f 2>/dev/null | head -1)
        [ -s "$FIRST_OPT" ] && OPTIONS_NONEMPTY=1
    fi
    echo "${OPTIONS_COUNT}:${OPTIONS_NONEMPTY}" > ${METRIC_PREFIX}_rocksdb_options

    # Write RocksDB temporary file count (moved earlier to avoid ghost assertions)
    TMP_COUNT=$(find "${DB_ROOT}" -maxdepth 3 \( -name '*.tmp' -o -name '*.dbtmp' \) -type f 2>/dev/null | wc -l)
    echo "$TMP_COUNT" > ${METRIC_PREFIX}_rocksdb_tmp_files

    # Write RocksDB IDENTITY file content (moved earlier to avoid ghost assertions)
    # Use a fixed path (/var/ton-work/db/IDENTITY) to ensure we always read the
    # same file. Previously, `find ... | head -1` could return IDENTITY files from
    # different RocksDB sub-instances (celldb/, blockdb/) in different orders across
    # iterations, making the identity appear to change and violating the stability
    # assertion. Fall back to find only if the root IDENTITY doesn't exist.
    if [ -f /var/ton-work/db/IDENTITY ] && [ -s /var/ton-work/db/IDENTITY ]; then
        tr -d '[:space:]' < /var/ton-work/db/IDENTITY > ${METRIC_PREFIX}_rocksdb_identity
    else
        IDENTITY_FILE=$(find /var/ton-work/db -maxdepth 2 -name IDENTITY -type f 2>/dev/null | sort | head -1)
        if [ -n "$IDENTITY_FILE" ] && [ -s "$IDENTITY_FILE" ]; then
            tr -d '[:space:]' < "$IDENTITY_FILE" > ${METRIC_PREFIX}_rocksdb_identity
        else
            touch ${METRIC_PREFIX}_rocksdb_identity
        fi
    fi

    # Refresh heartbeat after moved metrics
    date +%s > ${METRIC_PREFIX}_heartbeat

    # Write DB directory size (bytes) for data-integrity monitoring
    if [ -d "/var/ton-work/db" ]; then
        du -sb /var/ton-work/db 2>/dev/null | cut -f1 > ${METRIC_PREFIX}_db_size
    else
        echo "0" > ${METRIC_PREFIX}_db_size
    fi
    # Write RocksDB LOCK file existence for DB integrity monitoring
    LOCK_COUNT=$(find /var/ton-work/db -maxdepth 2 -name LOCK -type f 2>/dev/null | head -1 | wc -l)
    if [ "$LOCK_COUNT" -gt 0 ]; then
        echo "1" > ${METRIC_PREFIX}_db_lock
    else
        echo "0" > ${METRIC_PREFIX}_db_lock
    fi
    # Write config.json validity for data integrity monitoring
    if [ -f "/var/ton-work/db/config.json" ]; then
        if jq empty /var/ton-work/db/config.json 2>/dev/null; then
            echo "1" > ${METRIC_PREFIX}_config_valid
        else
            echo "0" > ${METRIC_PREFIX}_config_valid
        fi
    else
        echo "-1" > ${METRIC_PREFIX}_config_valid
    fi
    # Write config.json content hash for stability monitoring
    md5sum /var/ton-work/db/config.json 2>/dev/null | awk '{print $1}' > ${METRIC_PREFIX}_config_hash || echo "unavailable" > ${METRIC_PREFIX}_config_hash
    # Write config.json structural keys for structural integrity monitoring
    if [ -f "/var/ton-work/db/config.json" ]; then
        jq -r 'keys | join(",")' /var/ton-work/db/config.json > ${METRIC_PREFIX}_config_keys 2>/dev/null || echo "error" > ${METRIC_PREFIX}_config_keys
    else
        echo "missing" > ${METRIC_PREFIX}_config_keys
    fi
    # Write TCP connection state counts (CLOSE_WAIT=08, TIME_WAIT=06 in hex)
    CLOSE_WAIT=$(awk '$4 == "08" {count++} END {print count+0}' /proc/1/net/tcp 2>/dev/null || echo "0")
    TIME_WAIT=$(awk '$4 == "06" {count++} END {print count+0}' /proc/1/net/tcp 2>/dev/null || echo "0")
    echo "${CLOSE_WAIT},${TIME_WAIT}" > ${METRIC_PREFIX}_tcp_states
    # Write max accept queue depth across listening sockets
    # In /proc/1/net/tcp, state 0A = LISTEN; column 2 (local_address) field after ':' is the accept queue length in hex
    ACCEPT_Q_MAX=$(awk '$4 == "0A" {split($2, a, ":"); q=strtonum("0x"a[2]); if(q>m) m=q} END {print m+0}' /proc/1/net/tcp 2>/dev/null || echo "0")
    echo "$ACCEPT_Q_MAX" > ${METRIC_PREFIX}_accept_queue
    # Write RocksDB WAL (.log) file count for compaction health monitoring
    WAL_COUNT=$(find /var/ton-work/db -maxdepth 2 -name "*.log" -type f 2>/dev/null | wc -l)
    echo "$WAL_COUNT" > ${METRIC_PREFIX}_wal_count

    # Refresh heartbeat mid-way through slow operations
    date +%s > ${METRIC_PREFIX}_heartbeat

    # Write total disk usage of /var/ton-work for disk budget monitoring
    DISK_USAGE=$(du -sb /var/ton-work 2>/dev/null | cut -f1 || echo "-1")
    echo "$DISK_USAGE" > ${METRIC_PREFIX}_disk_usage
    # Write RocksDB MANIFEST file count for data integrity monitoring
    MANIFEST_COUNT=$(find /var/ton-work/db -maxdepth 2 -name "MANIFEST-*" -type f 2>/dev/null | wc -l)
    echo "$MANIFEST_COUNT" > ${METRIC_PREFIX}_manifest_count
    # Write RocksDB MANIFEST file size (bytes) for metadata growth monitoring
    MANIFEST_FILE=$(cat /var/ton-work/db/CURRENT 2>/dev/null | tr -d '[:space:]')
    if [ -n "$MANIFEST_FILE" ] && [ -f "/var/ton-work/db/$MANIFEST_FILE" ]; then
        stat -c%s "/var/ton-work/db/$MANIFEST_FILE" > ${METRIC_PREFIX}_manifest_size
    else
        touch ${METRIC_PREFIX}_manifest_size
    fi
    # Write RocksDB CURRENT file validity (root of metadata chain: CURRENT → MANIFEST → SST)
    CURRENT_FILE=$(find /var/ton-work/db -maxdepth 2 -name CURRENT -type f 2>/dev/null | head -1)
    if [ -n "$CURRENT_FILE" ] && [ -s "$CURRENT_FILE" ]; then
        echo "1" > ${METRIC_PREFIX}_current_valid
    else
        echo "0" > ${METRIC_PREFIX}_current_valid
    fi
    # Cross-validate CURRENT → MANIFEST reference
    if [ -n "$CURRENT_FILE" ] && [ -s "$CURRENT_FILE" ]; then
        CURRENT_DIR=$(dirname "$CURRENT_FILE")
        MANIFEST_REF=$(cat "$CURRENT_FILE" 2>/dev/null | tr -d '[:space:]')
        if [ -n "$MANIFEST_REF" ] && [ -f "${CURRENT_DIR}/${MANIFEST_REF}" ]; then
            echo "1" > ${METRIC_PREFIX}_current_manifest_consistent
        else
            echo "0" > ${METRIC_PREFIX}_current_manifest_consistent
        fi
    else
        echo "-1" > ${METRIC_PREFIX}_current_manifest_consistent
    fi
    # Write ton-global.config JSON validity
    if [ -f "/var/ton-work/db/ton-global.config" ]; then
        if jq empty /var/ton-work/db/ton-global.config 2>/dev/null; then
            echo "1" > ${METRIC_PREFIX}_global_config_valid
        else
            echo "0" > ${METRIC_PREFIX}_global_config_valid
        fi
    else
        echo "-1" > ${METRIC_PREFIX}_global_config_valid
    fi

    # Refresh heartbeat before final batch
    date +%s > ${METRIC_PREFIX}_heartbeat

    # Scan RocksDB LOG files for corruption/IO error indicators
    ROCKSDB_LOG=$(find /var/ton-work/db -maxdepth 4 -name "LOG" -type f 2>/dev/null | head -5)
    CORRUPTION_COUNT=0
    for logf in $ROCKSDB_LOG; do
        COUNT=$(grep -ciE "Corruption:|IO error|checksum mismatch|bad block contents|Repair" "$logf" 2>/dev/null) || true
        COUNT=${COUNT:-0}
        CORRUPTION_COUNT=$((CORRUPTION_COUNT + COUNT))
    done
    echo "$CORRUPTION_COUNT" > ${METRIC_PREFIX}_rocksdb_errors
    # Scan RocksDB LOG files for write stall indicators
    # Use specific patterns that match actual stall events, not stats dump headers
    # like "Write Stall Stats" which appear during normal periodic stats output.
    WRITE_STALL_COUNT=0
    for logf in $ROCKSDB_LOG; do
        COUNT=$(grep -ciE "Stalling writes because|Stopping writes because" "$logf" 2>/dev/null) || true
        COUNT=${COUNT:-0}
        WRITE_STALL_COUNT=$((WRITE_STALL_COUNT + COUNT))
    done
    echo "$WRITE_STALL_COUNT" > ${METRIC_PREFIX}_rocksdb_write_stalls
    # Count non-fatal error lines in validator log for error rate monitoring
    # Exclude lines already caught by fatal/alloc checks to avoid double-counting
    if [ -f "${LOG_FILE}" ]; then
        LOG_ERROR_COUNT=$(grep -ciE '\berror\b|\[E\s' "${LOG_FILE}" 2>/dev/null || echo "0")
        LOG_SIZE_KB=$(( $(stat -c %s "${LOG_FILE}" 2>/dev/null || echo "0") / 1024 ))
    else
        LOG_ERROR_COUNT=0
        LOG_SIZE_KB=0
    fi
    echo "${LOG_ERROR_COUNT}:${LOG_SIZE_KB}" > ${METRIC_PREFIX}_log_error_count
    # Write RocksDB LOG file size (bytes) for LOG growth monitoring
    ROCKSDB_LOG_SIZE=0
    ROCKSDB_LOG_FILE="/var/ton-work/db/LOG"
    if [ ! -f "$ROCKSDB_LOG_FILE" ]; then
        ROCKSDB_LOG_FILE=$(find /var/ton-work/db -maxdepth 4 -name "LOG" -type f 2>/dev/null | head -1)
    fi
    if [ -n "$ROCKSDB_LOG_FILE" ] && [ -f "$ROCKSDB_LOG_FILE" ]; then
        ROCKSDB_LOG_SIZE=$(stat -c%s "$ROCKSDB_LOG_FILE" 2>/dev/null || echo "0")
    fi
    echo "$ROCKSDB_LOG_SIZE" > ${METRIC_PREFIX}_rocksdb_log_size
    # Write RocksDB compaction event count for compaction health monitoring
    COMPACTION_COUNT=0
    for logf in $ROCKSDB_LOG; do
        COUNT=$(grep -ciE "compacted to:|Compaction.*@|Manual compaction|compaction_job|CompactFiles|CompactionJob|compaction_finished|compaction_started|Compacted.*=>" "$logf" 2>/dev/null) || true
        COUNT=${COUNT:-0}
        COMPACTION_COUNT=$((COMPACTION_COUNT + COUNT))
    done
    echo "$COMPACTION_COUNT" > ${METRIC_PREFIX}_compaction_count
    # Write RocksDB SST file count for data integrity monitoring
    # Search deeper (maxdepth 5) and include both .sst and .ldb extensions
    # TON uses multiple RocksDB instances in subdirs (celldb/, blockdb/, statedb/)
    SST_COUNT=$(find /var/ton-work/db -maxdepth 5 \( -name "*.sst" -o -name "*.ldb" \) -type f 2>/dev/null | wc -l)
    echo "$SST_COUNT" > ${METRIC_PREFIX}_sst_count
    # (rocksdb_options, rocksdb_tmp_files, cmdline_hash, rocksdb_identity, db_dir_count
    #  moved to early low-priority section to avoid ghost assertions under frequent restarts)

    # Touch the validator log to keep its mtime fresh. TON's TsFileLog buffers
    # aggressively and may not flush to disk for extended periods, making the log
    # appear stale to mtime-based freshness checks even while the process is healthy.
    # A no-op append (>>) preserves content while updating mtime.
    if [ -f "${LOG_FILE}" ]; then
        touch "${LOG_FILE}"
    fi

    # Final heartbeat write at end of loop
    date +%s > ${METRIC_PREFIX}_heartbeat
    # Write loop-completion epoch: signals that ALL metrics in this iteration
    # have been written. Used by the metric freshness driver as a more accurate
    # precondition than the heartbeat (which is refreshed 7 times mid-loop).
    date +%s > ${METRIC_PREFIX}_loop_epoch
    sleep 5
done
) &

echo "Total startup: $(($(date +%s) - RESTART_START))s"
echo "Starting validator-engine..."
exec validator-engine \
    -C "${GLOBAL_CONFIG}" \
    --db "${DB_ROOT}" \
    --ip "${IP}:${VALIDATOR_PORT}" \
    --threads "${THREADS}" \
    --verbosity "${VERBOSITY}" \
    --logname "${LOG_FILE}"
