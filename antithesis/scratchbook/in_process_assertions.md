# In-Process Antithesis SDK Assertions

This document catalogs the in-process assertions embedded in the TON validator C++ code using the Antithesis C++ SDK.

## Validator Block Processing (validator/invariants.hpp)
- ~40 ALWAYS/REACHABLE assertions covering block acceptance, application, proof verification, and proof link verification

## Block Validation (validator/impl/validate-query.cpp)
- 6 ALWAYS: file hash, root hash, state hash, Merkle update validity, generation time consistency
- 3 REACHABLE: validation pipeline entry points

## Block Construction / Collator (validator/impl/collator.cpp)
- REACHABLE on collation start/completion/error
- ALWAYS on value flow conservation, Merkle update consistency, file hash integrity, structural validation, block candidate size limits

## Liteserver API Layer (validator/impl/liteserver.cpp)
- 3 REACHABLE: query dispatch, completion, abort
- 6 ALWAYS: response non-empty, block data non-null, block ID matches, state non-null, data integrity checks

## ADNL Networking Layer (adnl/adnl-peer.cpp, adnl/adnl-packet.cpp)
- adnl-peer.cpp: 8 ALWAYS + 3 REACHABLE (seqno monotonicity, duplicate detection, query ID uniqueness, MTU bounds, channel key matching, huge message hash verification)
- adnl-packet.cpp: 3 ALWAYS + 1 REACHABLE (packet flags validity, message flag type validation)

## Catchain Layer (catchain/catchain-received-block.cpp, catchain/catchain-receiver.cpp)

### catchain-received-block.cpp
- **REACHABLE "Catchain block delivered"**: Core delivery path is exercised (in `deliver()`)
- **ALWAYS "Catchain delivered block has no pending dependencies"**: pending_deps == 0 when delivering
- **ALWAYS "Catchain delivered block is persisted in DB"**: in_db is true when delivering
- **ALWAYS "Catchain delivered block was in initialized state"**: state == bs_initialized when delivering
- **ALWAYS "Catchain block height is exactly one more than predecessor"**: Height chain invariant (height == prev_height + 1)
- **REACHABLE "Catchain fork proof detected"**: Fork detection path is exercised (in `pre_deliver(fork)`)
- **ALWAYS "Catchain fork proof blocks have same height"**: Fork proof validity — both blocks same height
- **ALWAYS "Catchain fork proof blocks have same source"**: Fork proof validity — both blocks same source
- **ALWAYS "Catchain fork proof blocks have different data hashes"**: Fork proof validity — blocks have different data
- **ALWAYS "Catchain block assigned a valid fork ID"**: fork_id > 0 after assignment (in `initialize_fork()`)

### catchain-receiver.cpp
- **REACHABLE "Catchain block received from network"**: Network receive path is exercised (in `receive_block()`)
- **ALWAYS "Catchain received block source ID is within bounds"**: src_id < sources_cnt on receive
- **REACHABLE "Catchain block delivered to callback"**: Callback delivery path is exercised (in `deliver_block()`)
- **ALWAYS "Catchain delivered block has positive height"**: height > 0 on callback delivery
- **ALWAYS "Catchain delivered block serialization within size limit"**: Serialized block size <= max_serialized_block_size

### Summary
- 4 REACHABLE: block delivery, fork proof detection, block received from network, block delivered to callback
- 11 ALWAYS: delivery preconditions (no pending deps, in DB, initialized state), height chain invariant, fork proof validity (same height, same source, different hash), valid fork ID, source ID bounds, positive height, serialization size bound
