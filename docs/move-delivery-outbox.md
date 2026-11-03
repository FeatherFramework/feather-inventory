# Durable move delivery — one-batch deployment and acceptance

2026-11-02 prepared restart acceptance workflow IMPLEMENTED/local tests PASS; live acceptance PENDING. One co-deployment packages full RedM process restart then MariaDB service restart, with persistent pre-dispatch baselines and no preparation replay. Jane/John are discovered by their stable character IDs. Both normal owners seal/restore before baseline capture. Inventory persists and pauses ONLY an abandoned diagnostic reservation and redelivery of an already-recorded Lasso229 projection, with no gameplay item mutation. Workers resume the diagnostic records after a new server-process convar token (server case), or an observed SQL outage plus decreasing MariaDB Uptime (database case). The live database test must keep the same RedM process. Verification requires normal rollback/scope release, original delivery event IDs/unique provenance, healthy queues and exact saved Inventory/ammo/equipment/native ownership/wear conservation (new session/epoch permitted). A resource-only restart or network outage alone cannot pass. Existing gameplay feature switches are recorded; explicit settings command reapplies only12 whitelisted boolean gameplay switches after a new server process while clients are disconnected. Issuance/fault flags are excluded; this is not acceptance of permanent installer startup configuration. Files native-restart-probe.json and native-restart-report.json are durable evidence and must be preserved. Earlier lifecycle report remains separate. Tests: Inventory Lua/91 runtime syntax plus JS3; Weapons221 Lua/runtime syntax plus JS7. User identified database Windows service MariaDB. One final visual pass remains after both scenarios. Scope is PREPARED GRACEFUL RESTART with abandoned reservation and idempotent existing delivery, not arbitrary in-flight purchase/transfer COMMIT, hard process kill/power loss, all economic APIs, or third-party callback guarantees. See Weapons docs/native-restart-acceptance.md for eight-file co-deployment and every command/UI action.

2026-11-02 LIVE recovery maintenance acceptance PASS. InvMoveMaintenanceAcceptance returned phase passed/checks9/retentionDays30, fixtureRollbackConfirmed=true, unresolvedPreserved=true, recentPreserved=true, activeScopesPreserved=true, oldSettledRemoved=true, health healthy, gameplayWrites0 and provenanceWrites0. The reported ROLLBACK (39 queries,2555ms) was the intentional diagnostic rollback, not a failed gameplay transfer. InvMoveHealth independently returned healthy, pendingMoves0, pendingDeliveries0, pendingRefreshes0, activeScopes0, all oldest ages0, automaticMutationRetries0 and weaponDeduplicationPolicy retain. Automatic cleanup reported phase complete/removed0/batchLimit25/retentionDays30. Removal of eligible diagnostic records was proved within the rolled-back acceptance transaction; do not claim real aged production rows were deleted (worker removed0). This accepts the live schema, cleanup predicate/transaction rollback/readback and health-report gate. No additional copy, restart, manual SQL or repeat functional testing required for this batch. Required receiver deduplication/provenance remain retained. Whole database/RedM process restart/crash recovery and arbitrary third-party acknowledged delivery remain outside this accepted scope.

2026-11-02 recovery maintenance IMPLEMENTED and locally verified; live acceptance pending. Inventory automatically initializes completed_at/delivered_at timestamps and a cleanup index. Every minute a bounded worker gives legacy completed records a fresh grace period (up to100 timestamp initializations/table/pass), selects up to25 eligible operations, locks scope->outcome->outbox and rechecks completion, refresh, delivery, age and active scopes before atomically removing Inventory outcome/outbox payloads. Both outcome and acknowledged delivery must be at least30 days old; old pending work, recent delivery, pending refresh and active scopes are preserved. Committed rows lacking an outbox are conservatively retained. Weapons provenance, receiver deduplication receipts, saved reports and idle scope rows are NEVER pruned by this service: delayed delivery must retain its deduplication evidence. Health is automatic/quiet while healthy; console InvMoveHealth reports healthy/waiting/attention/unavailable, pending move/delivery/refresh counts/ages, active scopes and last cleanup. Console-only InvMoveMaintenanceAcceptance performs9 checks using8 diagnostic receipts in a deliberately rolled-back transaction and independent readback; no gameplay/provenance writes, no fixture movement, no player IDs required. Local Inventory Lua suite/90 runtime syntax, JS3 and Weapons220 Lua pass, including lost cleanup acknowledgement, upgrade grace, unresolved/recent delivery/refresh/scope preservation and health states. Live schema/rollback/health command acceptance remains pending. This does not extend the earlier accepted outbox gate to whole database/RedM process crashes or arbitrary third-party callbacks. See Inventory docs/move-maintenance.md for the three-file Inventory-only deployment and complete commands.

2026-11-02 LIVE durable move delivery acceptance PASS. InvMoveRecoveryAcceptance returned phase passed/checks4, backgroundRecovered=true, lateOriginalFenced=true, rollback=true, lostCallerReply=true, itemWrites0, automaticMutationRetries0. No deadlock was shown in the supplied run; slow successful queries/commits are timing observations, not failures. Jane's existing Lasso229 committed inventory2->15 and15->2. Weapons persisted durable transitions with delivery IDs 494759f8-d693-11f1-99a9-e0d55eaa2deb:1 and 4cab8b3b-d693-11f1-99a9-e0d55eaa2deb:1. InvMoveDeliveryAcceptance returned phase passed/checks4, roundtrip=true, duplicateDeliveryConserved=true, durableSnapshots=true, provenanceEvents2, newProvenanceEvents0, itemWrites0, automaticMutationRetries0. User confirmed all requested manual observations passed. This accepts the scoped real Inventory/Weapons outbox/export/ledger path and duplicate-delivery conservation. No further deployment, restart or repeat testing is required for this gate. Remaining boundaries: arbitrary third-party broadcast subscribers are best-effort; no claim of whole DB/RedM process crash acceptance, every economic API, chronological delivery, or receipt retention/pruning policy.

Implemented and locally verified 2026-11-01; LIVE accepted 2026-11-02. Earlier ordinary-move recovery and visual gates remain accepted.

## Scope and contract

Inventory commits an immutable outbox document with the original move and outcome receipt. Failure to append rolls back the original mutation. Source/destination character owners are captured from SQL before a source container can be deleted, so offline owners and historical revisions remain available. Queued delivery survives resource restart and never re-executes inventory/equipment/ammunition writes. The consumer receives the EXACT stored document, not a reconstructed view of the item's current location.

Weapons accepts only feather-inventory as caller, validates catalog/serial/revision, then locks a payload-checked operation receipt and inserts provenance in that same InnoDB transaction. A repeated delivery returns the existing event IDs. A changed payload for the same operation refuses. An unknown consumer commit reply remains unacknowledged in Inventory; redelivery determines the original durable result without duplicating its ledger records. Both receipt and provenance tables must be InnoDB before Weapons becomes ready.

Legacy Inventory broadcasts remain present for existing consumers; the durable operation tag makes Weapons skip its old insert path. Historical broadcasts are NOT replayed. Inventory UI/hotbar refreshes repeat safely against current character sessions, never stale player IDs. OwnershipTransitionCommitted is still a best-effort compatibility signal: its arbitrary subscribers are not transactionally acknowledged. Container-deletion facts remain in the outbox document; no unknown subscriber/economy side effects are replayed. This batch guarantees the built-in provenance projection and repeatable refreshes, not exactly-once arbitrary callbacks, chronological delivery, every economy API or whole DB/RedM crash acceptance. Existing pre-outbox moves are not backfilled or re-emitted. Receipts/outbox records are retained; pruning remains future work.

Ordered scope upserts now acquire exclusive locks directly, avoiding the INSERT IGNORE-to-FOR UPDATE lock upgrade pattern. The prior live deadlock was safely rolled back; its exact source cannot be proven from logs alone, and this change does not promise no future deadlocks.

## Required runtime files

Copy ONLY these nine staged files. Co-deploy both resources while Weapons is stopped; do not run a mixed-version observer/producer pair.

| Absolute local source | Absolute server destination |
| --- | --- |
| `C:\coding\move-delivery-deploy\feather-inventory\server\controllers\inventory.lua` | `C:\Servers\redm_feather\server\resources\[feather]\feather-inventory\server\controllers\inventory.lua` |
| `C:\coding\move-delivery-deploy\feather-inventory\server\internal\move_recovery.lua` | `C:\Servers\redm_feather\server\resources\[feather]\feather-inventory\server\internal\move_recovery.lua` |
| `C:\coding\move-delivery-deploy\feather-inventory\server\services\move_recovery.lua` | `C:\Servers\redm_feather\server\resources\[feather]\feather-inventory\server\services\move_recovery.lua` |
| `C:\coding\move-delivery-deploy\feather-inventory\server\services\move_outbox.lua` | `C:\Servers\redm_feather\server\resources\[feather]\feather-inventory\server\services\move_outbox.lua` |
| `C:\coding\move-delivery-deploy\feather-inventory\server\services\guards.lua` | `C:\Servers\redm_feather\server\resources\[feather]\feather-inventory\server\services\guards.lua` |
| `C:\coding\move-delivery-deploy\feather-weapons\fxmanifest.lua` | `C:\Servers\redm_feather\server\resources\[feather]\feather-weapons\fxmanifest.lua` |
| `C:\coding\move-delivery-deploy\feather-weapons\server\main.lua` | `C:\Servers\redm_feather\server\resources\[feather]\feather-weapons\server\main.lua` |
| `C:\coding\move-delivery-deploy\feather-weapons\server\services\move_delivery.lua` | `C:\Servers\redm_feather\server\resources\[feather]\feather-weapons\server\services\move_delivery.lua` |
| `C:\coding\move-delivery-deploy\feather-weapons\server\services\ownership.lua` | `C:\Servers\redm_feather\server\resources\[feather]\feather-weapons\server\services\ownership.lua` |

Preserve deployed configuration, native-recovery-batch.json, native-acceptance-report.json and other files. Tests and documentation are optional/local only and must not be copied as runtime files. No UI build or MySQL resource change is needed. Two new tables initialize automatically: inventory_move_outbox and feather_weapon_move_receipts. No manual SQL migration/config changes/full server restart. Refresh is required for the new service files and Weapons manifest entry.

## Commands/actions in execution order

Server console before copying:

```text
InvNativeRecoveryBatch status
WeaponNativePrepareStopAll
WeaponNativeShutdownStatus
```

Require recovery idle/cleared and aggregate PASS, phase ready, completed=total. Retain any failure output rather than bypassing it. Then server console:

```text
stop feather-weapons
```

Fully quit both RedM clients. Copy the nine files above, merging their folder paths into the two resources. Server console:

```text
refresh
restart feather-inventory
restart bcc-stashes
ensure feather-weapons
```

Check startup has no schema/readiness failure. Reconnect Jane and John once. Server console (existing Config.DevMode=true required):

```text
InvMoveRecoveryAcceptance
```

Expect phase passed/checks4/itemWrites0/automaticMutationRetries0. This rechecks the changed scope acquisition and outbox transaction composition using receipts only; it does not move the fixture.

As Jane, use the existing test box UI to move her UNEQUIPPED Lasso into storage once, close/reopen to confirm exactly one in the box and none with Jane, then return it once and confirm exactly one with Jane and none in the box. This is the existing item229/serial FW-LASS-6AE6BCBA-26771B-0001; no new grant, equip or SQL query is needed. A new post-deployment round-trip is required because earlier accepted moves predate the outbox. Check Jane's equipped firearms still draw and John's wheel is unchanged. Wait about five seconds for background delivery, then server console:

```text
InvMoveDeliveryAcceptance
```

Expected phase passed/checks4/roundtrip true/duplicateDeliveryConserved true/durableSnapshots true/provenanceEvents2/newProvenanceEvents0/itemWrites0. The command discovers the fixture snapshots automatically from the latest100 outbox records, checks their revision sequence, performs independent SQL-backed audits through Weapons, redelivers each ALREADY recorded projection twice and compares its unchanged event IDs/unique ledger count. It does not move items or fabricate provenance. No player IDs required.

A waiting/wait_for_background_delivery response means the worker has not acknowledged both records yet: wait a few seconds and repeat only the inspection command. If review_required appears, retain the output; do not repeat moves or issue replacement items. Send the two command reports and the observation. No death/reconnect loop, database interruption, SQL dumps or eight-utility retest requested.

## Local evidence and limits

Inventory full Lua suite passes (89 runtime syntax files), including actual recovery/outbox composition: append failure rolls back original writes and receipt; unknown commit preserves exactly one original mutation/outbox record. Worker model covers consumer outage/restart, stable payload and current-recipient refresh. Console wiring covers fixture discovery, four duplicate deliveries and before/after audits without item writes. Weapons220 Lua specs/runtime syntax pass; model exercises receipt+ledger atomic rollback, lost committed reply, restart-equivalent receipt reuse, changed-payload refusal and duplicate-ledger detection. Inventory JS3 and Weapons JS7 pass. These tests model storage/exports; the real InnoDB consumer/export path still needs the live gate above. Earlier real provider/wire fault tests remain accepted, not repeated here.
