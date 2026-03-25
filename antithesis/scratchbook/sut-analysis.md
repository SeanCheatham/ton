# SUT Analysis: TON Blockchain Node

## Architecture Overview

TON (The Open Network) is a blockchain node implementation written in C++20, built with CMake and Clang. The primary executable is `validator-engine`, which runs the full validator node including consensus, networking, and state management.

### Key Components

- **validator-engine**: Main entry point; runs the validator node process
- **ADNL (Anonymous Distributed Network Layer)**: Custom P2P networking protocol
- **DHT**: Distributed hash table for peer discovery
- **Catchain**: Consensus protocol for validator sessions
- **Overlay**: Overlay network management
- **Crypto/VM**: TVM (TON Virtual Machine) for smart contract execution
- **RocksDB**: Persistent key-value storage for blockchain state
- **tdactor**: Actor-based concurrency framework used throughout

### Concurrency Model

The system uses an actor model (tdactor) for concurrency. Each major subsystem (validator manager, network handlers, storage) runs as actors with message-passing. Thread pools handle parallel work. This is a rich target for Antithesis — actor message ordering, concurrent state updates, and timing-dependent consensus all benefit from systematic exploration.

### State Management

- Blockchain state stored in RocksDB
- In-memory caches for active validator sessions
- State serialization for snapshots and archives
- Cell-based Merkle tree data structures

### Communication

- UDP-based ADNL protocol between nodes
- TCP console port for validator-engine-console
- Liteserver port for lite-client queries

## Failure-Prone Areas

1. **Consensus/Catchain**: Timing-sensitive agreement protocol between validators
2. **State serialization**: Complex state snapshots that must be consistent
3. **Network partitions**: ADNL overlay handling during connectivity issues
4. **Concurrent actor interactions**: Message ordering in the actor system
5. **RocksDB operations under load**: Storage layer during high throughput

## Assumptions

- The validator-engine can operate in a standalone/single-node mode for basic testing
- The existing Dockerfile provides a working build pipeline
- Clang 21 is the target compiler (already in the Dockerfile)

## Memory Health Assertions

The following memory-related assertions are tracked:

- **mem_bounded**: Absolute RSS < 2GB
- **vmsize_bounded**: Absolute VmSize bounded
- **mem_peak**: VmPeak bounded
- **mem_growth**: RSS not monotonically growing (trajectory detection via history)
- **mmap_bounded**: Memory mapping count < 10,000
- **RSS-to-VmSize ratio**: VmSize/VmRSS ratio < 10× — detects memory fragmentation where virtual address space grows much faster than physical usage
- **mmap_growth**: Memory mapping count not monotonically growing — detects slow mmap leaks (RocksDB SST handles, arena creation without release) before hitting absolute bound

## Open Questions

- What is the minimum viable topology for meaningful consensus testing? (likely 3+ validators)
- Can the system bootstrap a private network without external config downloads?
