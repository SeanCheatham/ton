# Liteserver Assertions — Investigation & Fix

## C++ Assertions (in validator/impl/liteserver.cpp)

| Assertion | Type | Location | Fires When |
|---|---|---|---|
| `Liteserver query dispatched` | REACHABLE | `LiteQuery::perform()` | Any lite-client query is received and dispatched |
| `Liteserver query finished successfully` | REACHABLE | `LiteQuery::finish_query()` | A query completes and returns a non-empty result |
| `Liteserver query aborted` | REACHABLE | `LiteQuery::abort_query()` | A query fails (e.g., block not found, timeout) |
| `Liteserver response is non-empty` | ALWAYS_OR_UNREACHABLE | `LiteQuery::finish_query()` | Every successful response must be non-empty |

All four assertions are **SUT-side** (fire inside validator-engine), triggered by actual lite-client queries reaching the liteserver subsystem.

## Workload Assertion (in parallel_driver_liteclient_query.sh)

| Assertion | Type |
|---|---|
| `Lite-client can query validator and get a response` | Sometimes (must_hit) |

## Root Cause: Timing Gap

The parallel driver `parallel_driver_liteclient_query.sh` was **silently skipping every invocation** during `snouty validate` because of a heartbeat timing gap:

1. The validator's background heartbeat loop (in `entrypoint-validator.sh`) only writes `/shared/validator_heartbeat` after `validator-engine` is exec'd as PID 1.
2. Genesis coordination can take 10-60 seconds before exec.
3. The workload entrypoint waits for TCP ports, then emits `setup_complete`.
4. Test Composer immediately starts parallel drivers.
5. The first heartbeat may not exist yet — the parallel driver sees "Heartbeat file not present yet" and `exit 0`.
6. By the time the heartbeat appears (5s after exec), snouty validate may already be finishing.

**Result**: Zero lite-client queries ever reach the validator, so all four C++ assertions remain unhit.

## Fix Applied

### 1. `first_wait_for_liteserver.sh` (new)

A `first_*` script that blocks until all liteserver prerequisites are met:
- Heartbeat file exists with a valid timestamp
- Liteserver TCP port (30003) accepts connections
- Liteserver config file exists at `/shared/liteserver.config.json`
- lite-client can connect and get any response

Test Composer runs `first_*` scripts before parallel drivers, so this guarantees the timing gap is closed.

### 2. `parallel_driver_liteclient_query.sh` (updated)

Replaced the immediate-skip heartbeat check with a 20-second retry loop:
- Polls every 2 seconds for the heartbeat file
- If heartbeat appears within the window, proceeds with the query
- If heartbeat is stale (age > 60s), still skips (validator may be dead)
- If heartbeat doesn't appear after 20s, skips (same as before, but with patience)

## Expected Behavior After Fix

**During snouty validate (~2-3 min window):**
- `first_wait_for_liteserver.sh` blocks for 10-30s until liteserver is ready
- `parallel_driver_liteclient_query.sh` finds heartbeat on first/second poll
- lite-client queries reach validator-engine's liteserver subsystem
- **"Liteserver query dispatched"** fires (REACHABLE) — query enters `perform()`
- **"Liteserver query finished successfully"** OR **"Liteserver query aborted"** fires depending on whether the validator has blocks to serve

**During full Antithesis runs:**
- All four C++ assertions fire regularly
- The workload `sometimes` assertion fires with `condition=true`
- Under fault injection, "Liteserver query aborted" fires when queries fail
- "Liteserver response is non-empty" validates every successful response
