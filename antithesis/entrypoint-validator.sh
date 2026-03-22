#!/usr/bin/env bash
set -euo pipefail

# Entrypoint for the TON validator-engine in the Antithesis environment.
# Starts validator-engine with a minimal local configuration.

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
    echo "Initializing validator-engine..."
    validator-engine \
        -C "${GLOBAL_CONFIG}" \
        --db "${DB_ROOT}" \
        --ip "${IP}:${VALIDATOR_PORT}" || true
fi

echo "Starting validator-engine..."
exec validator-engine \
    -C "${GLOBAL_CONFIG}" \
    --db "${DB_ROOT}" \
    --ip "${IP}:${VALIDATOR_PORT}" \
    --threads "${THREADS}" \
    --verbosity "${VERBOSITY}"
