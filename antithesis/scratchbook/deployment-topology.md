# Deployment Topology: TON Blockchain Node

## Topology

```text
+--------------------+      +--------------------+
| workload           | ---> | validator-engine   |
| (test driver)      | <--- | (SUT)              |
+--------------------+      +--------------------+
```

## Components

### validator-engine (Service / SUT)

- **Container name**: validator
- **Image source**: Custom Dockerfile adapted from repo root `Dockerfile`, with Antithesis instrumentation
- **Role**: Service (SUT)
- **What it runs**: `validator-engine` binary with a local/private network config
- **Network**: Exposes UDP port 30001 (validator), TCP port 30002 (console), TCP port 30003 (liteserver)
- **Replica count**: 1 (single node for bootstrap; expand to 3+ for consensus testing later)

### workload (Client)

- **Container name**: workload
- **Image source**: New lightweight Dockerfile (Debian slim with curl/netcat for health checks)
- **Role**: Client (test driver)
- **What it runs**: Emits `setup_complete`, then sleeps waiting for Test Composer commands
- **Network**: Connects to validator on console and liteserver ports
- **Replica count**: 1

## SDK Selection

- **C++ SDK** (`antithesis-sdk-cpp`): For SUT-side assertions in validator-engine
- **Shell-based setup_complete**: For the workload container (uses `setup-complete.sh`)

## Assumptions

- Single validator node is sufficient for bootstrap testing
- The validator-engine can start with a minimal local config (no external network needed)
- The workload container will use shell scripts for test commands

## Open Questions

- For consensus testing, we'll need 3+ validator nodes with a shared genesis config
- Whether lite-client can serve as the primary workload interaction tool
