# First optimization slice: live timing and capacity acceptance

This build batches drag/drop slot moves, occupied-slot swaps, compatible-stack merges, splits and automatic placement through MoveInventoryItems. The shared path covers ground drops, quick transfers and Take All's whole-set attempt. It retains one transaction for the whole move and validates exact affected-row counts. Failure in any chunk rolls back earlier chunks. Take All's per-item fallback and Give's browser-side one-request-per-item loop remain subsequent work. Take All now returns one fresh, access-checked post-commit inventory pair; the client no longer polls up to 20 times for a predicted item count.

Ground drops now use bounded membership preflight reads instead of loading each record individually. Membership and guards are rechecked under locks inside the move transaction. Source and target inventory policies are locked before source item rows. The complete automatic placement is planned before grouped writes; stack room, slots, quantities, restrictions and weight remain enforced.

The default is 100 records per UPDATE, bounded to 1–200. A stack of 200 records targeting one slot uses two UPDATE statements. Restriction checks during slot swaps/moves are reused per definition inside the operation, rather than repeated per record. Access, guards, weight and quantity checks remain inside the transaction; destination/source slot bounds are rechecked against locked policy rows. Swaps validate both resulting inventories. Splits and same-inventory rearrangement conserve total weight.

## Install the test build

Copy the updated resource's runtime Lua, config and complete built `ui/` together. Copying only `ui/` will not install the server optimization. The ZIP in `.artifacts/feather-inventory.zip` contains the complete runtime build. Preserve deployed server configuration changes, and merge the new config fields when replacing it.

Refresh and restart **only feather-inventory** after installing; newly added helper files must be picked up by the manifest globs. Leave Character and Core running. Reopen the inventory after restarting.

## Compare batch size 1 with 100

In the server console (omit slash):

```text
setr feather_inventory_mutation_timing 1
set feather_inventory_update_batch_size 1
```

Move a known 100- or 200-record stack into an empty slot, then repeat occupied-slot swaps, compatible merges and splits. Use legal stack definitions and actual capacity limits; do not raise limits just to force an unsupported fixture. Repeat each case five times, alternating direction where appropriate and restoring comparable starting contents for merges/splits. Test both personal-to-storage and storage-to-person moves. Exclude the first warm-up operation from steady-state comparisons, but record it separately.

Next switch in the server console, without restarting:

```text
set feather_inventory_update_batch_size 100
```

Repeat the same cases and sizes. Optionally repeat at 25, 50 and 200. Batch size is read when a write group is planned; wait until the current operation finishes before changing it. This size-1 comparison uses the same new validation and restriction-read reuse as the batched mode; it is a controlled write-batching comparison, not a recreation of every detail of the previous release.

Logs begin with `[inventory:mutation]` in the server console and browser/NUI console (normally visible in client F8 output). Match `id` and `traceId` between the entries. Each contains aggregate measurements, never item metadata.

For ground-drop acceptance, use the same item/quantity and compare a new empty ground pile with an existing compatible pile separately. The server log must contain `operation: ground_drop`; this confirms the full drop handler is timed. Quick transfer logs use `operation: move_items` with `reason: inventory_transfer` and `scope: controller`; server time there covers the controller rather than the whole RPC. Take All now logs operation: take_all for the complete RPC, followed by client and browser timing for the same trace. fallbackAttempts reports individual attempts when the full set does not fit.

| Field | Meaning |
| --- | --- |
| `serverMs` | Handler entry through validation, mutation, events and response construction; excludes response transport |
| `transactionMs` | Before DB.transaction through its return, including connection/lock waits and commit/rollback |
| `sqlMs` | Time awaiting transaction-bound SQL calls, including the provider bridge and SQL execution/locks |
| `sqlStatements` / `updateStatements` | Transaction query count / UPDATE count; exclude preflight and final response reads |
| `guardSnapshotMs` | Locked bulk equipment read before movement guards; included in transaction SQL time |
| `guardMs` / `guardConsumers` | Total movement guard time / calls and elapsed time per registered consumer |
| `eventEmissionMs` | Time spent emitting post-commit per-record events; deferred subscriber work is not fully covered |
| `responseReadMs` | Final authoritative inventory reads and metadata decoding |
| `sourceReadMs` / `fallbackAttempts` | Take All initial source read / individual attempts after the whole-set attempt fails |
| `plannedRows` | Rows submitted for write planning, including attempted chunks on a failed operation |
| `destinationGroups` | Automatic-placement destination slots; many small groups can still require multiple UPDATE statements |
| `dropPreflightMs` / `dropPreflightStatements` | Ground-drop membership preflight time / bounded SELECT count outside the transaction |
| `dropSetupMs` | Finding/creating the ground pile and registering its inventory |
| `groundBroadcastMs` | Ground-location read/broadcast time after the successful move |
| `clientRpcMs` | Client Lua RPC start through response arrival; includes server work and RPC transport |
| `browserAppliedMs` | Drop/split action through applying or rejecting the server response in Vue |
| `browserFrameMs` | Action through two browser animation frames after Vue reconciliation; approximate paint opportunity |
| `committed` / `outcome` | Transaction commit status (when reached) / operation outcome |

These elapsed durations come from separate local clocks; do not subtract their start timestamps. `sqlMs` is contained within transaction time, and transaction/event/read time is contained within server time: do not add all fields together. Browser frame timing is not proof of game compositor paint, and may be delayed when the NUI is hidden. Timings are diagnostic and have some overhead. Report median and slowest of five runs; collect more runs for a meaningful p95.

Keep a record of operation, direction, moved/occupied stack sizes, total inventory record counts, batch size, server/transaction/query/response/browser timings and pass/fail of capacity checks. Send the matching server and client log lines for unexpectedly slow runs. Connection-pool acquisition is included in transaction time but not separately instrumented in this slice.

## Capacity and correctness gates

- Move to an empty slot at exactly the destination weight limit, then attempt one unit over it. Repeat for the personal inventory and a storage inventory. The over-limit operation must leave both books unchanged.
- Swap stacks where the destination can accept its incoming stack but the source cannot accept the heavier displaced stack. The entire swap must reject.
- With the last slot occupied, swap within valid slot bounds. Splitting into another slot when none is free must reject. Recheck normal configured capacities; extra weight allowance must never create an extra slot.
- Merge into a nearly full compatible stack. Only available stack room may move; source remainder and total count must be correct. Different metadata must preserve the existing compatibility behavior.
- Repeat with two players targeting the same storage's last slot or weight allowance. Check authoritative state and reopen both inventories; no duplicates, loss or overfill is allowed. This requires joint live testing.
- Confirm IDs/metadata persist and rejected moves restore the browser's optimistic display. Resource interruption and real database rollback remain live acceptance gates.

After collecting results:

```text
setr feather_inventory_mutation_timing 0
set feather_inventory_update_batch_size 100
```

For persistent configuration, place the chosen convars in server.cfg. Timing defaults off and batching defaults to Config.UpdateBatchSize (100) when no convar override exists.

## Automated coverage

`lua5.4 tests/lua/slot_updates_spec.lua .` runs deterministic tests of the actual controllers and transaction adapter using a transactional SQL model. Optional local Python runner: `python tests/run_lua.py --lupa-dir .artifacts/lua-test-runtime`, with lupa installed there. These tests cover batching, rollback, capacity rejection, metadata compatibility and event/revision behavior. They do not validate MariaDB query plans, database locking, FXServer behavior or live responsiveness.
