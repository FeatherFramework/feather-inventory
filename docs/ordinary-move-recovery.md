# Ordinary inventory move recovery â€” deployment and acceptance

2026-11-02 LIVE recovery maintenance acceptance PASS. InvMoveMaintenanceAcceptance returned phase passed/checks9/retentionDays30, fixtureRollbackConfirmed=true, unresolvedPreserved=true, recentPreserved=true, activeScopesPreserved=true, oldSettledRemoved=true, health healthy, gameplayWrites0 and provenanceWrites0. The reported ROLLBACK (39 queries,2555ms) was the intentional diagnostic rollback, not a failed gameplay transfer. InvMoveHealth independently returned healthy, pendingMoves0, pendingDeliveries0, pendingRefreshes0, activeScopes0, all oldest ages0, automaticMutationRetries0 and weaponDeduplicationPolicy retain. Automatic cleanup reported phase complete/removed0/batchLimit25/retentionDays30. Removal of eligible diagnostic records was proved within the rolled-back acceptance transaction; do not claim real aged production rows were deleted (worker removed0). This accepts the live schema, cleanup predicate/transaction rollback/readback and health-report gate. No additional copy, restart, manual SQL or repeat functional testing required for this batch. Required receiver deduplication/provenance remain retained. Whole database/RedM process restart/crash recovery and arbitrary third-party acknowledged delivery remain outside this accepted scope.

2026-11-02 recovery maintenance IMPLEMENTED and locally verified; live acceptance pending. Inventory automatically initializes completed_at/delivered_at timestamps and a cleanup index. Every minute a bounded worker gives legacy completed records a fresh grace period (up to100 timestamp initializations/table/pass), selects up to25 eligible operations, locks scope->outcome->outbox and rechecks completion, refresh, delivery, age and active scopes before atomically removing Inventory outcome/outbox payloads. Both outcome and acknowledged delivery must be at least30 days old; old pending work, recent delivery, pending refresh and active scopes are preserved. Committed rows lacking an outbox are conservatively retained. Weapons provenance, receiver deduplication receipts, saved reports and idle scope rows are NEVER pruned by this service: delayed delivery must retain its deduplication evidence. Health is automatic/quiet while healthy; console InvMoveHealth reports healthy/waiting/attention/unavailable, pending move/delivery/refresh counts/ages, active scopes and last cleanup. Console-only InvMoveMaintenanceAcceptance performs9 checks using8 diagnostic receipts in a deliberately rolled-back transaction and independent readback; no gameplay/provenance writes, no fixture movement, no player IDs required. Local Inventory Lua suite/90 runtime syntax, JS3 and Weapons220 Lua pass, including lost cleanup acknowledgement, upgrade grace, unresolved/recent delivery/refresh/scope preservation and health states. Live schema/rollback/health command acceptance remains pending. This does not extend the earlier accepted outbox gate to whole database/RedM process crashes or arbitrary third-party callbacks. See Inventory docs/move-maintenance.md for the three-file Inventory-only deployment and complete commands.

2026-11-02 LIVE durable move delivery acceptance PASS. InvMoveRecoveryAcceptance returned phase passed/checks4, backgroundRecovered=true, lateOriginalFenced=true, rollback=true, lostCallerReply=true, itemWrites0, automaticMutationRetries0. No deadlock was shown in the supplied run; slow successful queries/commits are timing observations, not failures. Jane's existing Lasso229 committed inventory2->15 and15->2. Weapons persisted durable transitions with delivery IDs 494759f8-d693-11f1-99a9-e0d55eaa2deb:1 and 4cab8b3b-d693-11f1-99a9-e0d55eaa2deb:1. InvMoveDeliveryAcceptance returned phase passed/checks4, roundtrip=true, duplicateDeliveryConserved=true, durableSnapshots=true, provenanceEvents2, newProvenanceEvents0, itemWrites0, automaticMutationRetries0. User confirmed all requested manual observations passed. This accepts the scoped real Inventory/Weapons outbox/export/ledger path and duplicate-delivery conservation. No further deployment, restart or repeat testing is required for this gate. Remaining boundaries: arbitrary third-party broadcast subscribers are best-effort; no claim of whole DB/RedM process crash acceptance, every economic API, chronological delivery, or receipt retention/pruning policy.

2026-11-01 durable ordinary-move projections IMPLEMENTED; live acceptance pending. Inventory now appends an immutable outbox document in the SAME transaction as item writes and the outcome receipt, capturing item/serial/definition/revision and source/destination character identities (including offline owners). A background worker redelivers to a trusted Weapons export only until acknowledgement; Weapons atomically commits provenance plus a payload-checked receipt, so a lost consumer reply/restart cannot duplicate the ledger entry. Native ItemMoved broadcasts are tagged to suppress a second legacy Weapons insert. Current-session Inventory/hotbar refreshes may safely repeat. Legacy broadcast delivery (including arbitrary OwnershipTransitionCommitted/ContainerDeleted subscribers) remains best-effort: no arbitrary third-party callbacks are blindly replayed or claimed exactly-once. Deleted-container facts are retained but no generic subscriber acknowledgement protocol is claimed. Scope acquisition now uses ordered exclusive upserts instead of INSERT IGNORE shared-lock upgrades; this removes that known contention pattern but does not prove every live deadlock source eliminated. New schema auto-initializes and validates InnoDB/primary keys. No manual SQL migration/config change. Local verification: Inventory Lua including 89 runtime syntax files, actual original-mutation/outbox rollback/lost-reply composition, console fixture audit wiring; Weapons220 Lua/runtime syntax, JS7, Inventory JS3. New console InvMoveDeliveryAcceptance audits the two new Lasso229 round-trip snapshots and deliberately redelivers already-recorded projections twice, requiring unchanged event IDs and exactly one ledger event per delivery key, ZERO item writes/new provenance events. Requires a NEW single round-trip after this batch; no SQL dumps, grants, player IDs or repeat of eight utility tests. Whole DB/RedM crash acceptance, all economy APIs, third-party acknowledged subscriptions and retention policy remain outside this gate. See Inventory docs/move-delivery-outbox.md for the exact nine-file co-deployment and commands.

Implemented, locally verified and LIVE accepted 2026-11-01.

2026-11-01 LIVE ordinary move recovery acceptance PASS: InvMoveRecoveryAcceptance returned phase passed/checks4, lostCallerReply=true, rollback=true, lateOriginalFenced=true, backgroundRecovered=true, itemWrites0 and automaticMutationRetries0. One ER_LOCK_DEADLOCK/40001 transaction was explicitly rolled back during the run; the completed receipt diagnostic did not replay gameplay mutations. Do not describe the run as contention-free or infer the deadlock root cause from logs alone. User completed Jane's unequipped test Lasso229 stash round-trip: committed deposit inventory2->15 and pickup15->2 with the same immutable serial FW-LASS-6AE6BCBA-26771B-0001; all requested observations passed (one Lasso, Jane draws firearms, John wheel unchanged). No further deployment/restart/test is required to record this accepted gate. Remaining: review concurrent scope lock-upgrade contention (INSERT IGNORE followed by FOR UPDATE), durable post-commit outbox/consumer deduplication/provenance delivery, receipt retention, and broader crash acceptance. Bundle compatible follow-up fixes into the next deployment; do not repeat accepted utility/receipt tests without a concrete regression reason.



## Behavior and limits

Before ordinary Give/list/storage, drag/swap and split writes, Inventory reserves a durable UUID receipt and ordered per-inventory fence. The original transaction locks that fence and commits its outcome/result receipt with the item writes. Unknown replies are resolved under the same locks; a pending transaction is cancelled only after obtaining those locks. An original callback arriving later cannot mutate through a cancelled fence. Global provider deadlock retries cannot repeat this mutation callback. No gameplay mutation is automatically replayed.

The background worker scans up to 25 receipts per page every two seconds; abandoned pending reservations enter reconciliation after 30 seconds. That age selects candidates, never establishes an outcome. Database readback and harmless UI refresh may repeat. Restarts resume from database receipts. Both affected inventories remain reserved while a pending transaction is unresolved. Known committed transactions release their fences in their original commit. Authorization, weight, membership, equipment guards and revision checks remain in the normal transaction.

The two InnoDB tables are created and checked before Inventory becomes ready. No SQL import or manual schema edits are required. No new configuration flag enables routine recovery. English recovery strings resolve through each recipient's existing feather-settings language contract, with English fallback.

Inline recovered success delivers the normal controller events once. Background recovery refreshes current recipients but DOES NOT replay generic post-commit callbacks. A durable outbox with consumer deduplication/provenance delivery remains a separate requirement before claiming complete crash recovery. Existing grant, consumption, maintenance and other economic APIs retain their own receipt contracts. A newly submitted player action is a new operation, not a globally deduplicated client request. Receipts are retained without pruning; retention policy remains future work.

## Required runtime files

Copy only these seven staged files, preserving their folder paths:

| Absolute local source | Absolute server destination |
| --- | --- |
| `C:\coding\ordinary-move-recovery-deploy\feather-inventory\fxmanifest.lua` | `C:\Servers\redm_feather\server\resources\[feather]\feather-inventory\fxmanifest.lua` |
| `C:\coding\ordinary-move-recovery-deploy\feather-inventory\server\internal\move_recovery.lua` | `C:\Servers\redm_feather\server\resources\[feather]\feather-inventory\server\internal\move_recovery.lua` |
| `C:\coding\ordinary-move-recovery-deploy\feather-inventory\server\services\move_recovery.lua` | `C:\Servers\redm_feather\server\resources\[feather]\feather-inventory\server\services\move_recovery.lua` |
| `C:\coding\ordinary-move-recovery-deploy\feather-inventory\server\controllers\inventory.lua` | `C:\Servers\redm_feather\server\resources\[feather]\feather-inventory\server\controllers\inventory.lua` |
| `C:\coding\ordinary-move-recovery-deploy\feather-inventory\server\services\api.lua` | `C:\Servers\redm_feather\server\resources\[feather]\feather-inventory\server\services\api.lua` |
| `C:\coding\ordinary-move-recovery-deploy\feather-inventory\server\services\callbacks.lua` | `C:\Servers\redm_feather\server\resources\[feather]\feather-inventory\server\services\callbacks.lua` |
| `C:\coding\ordinary-move-recovery-deploy\feather-inventory\translations\en_us.lua` | `C:\Servers\redm_feather\server\resources\[feather]\feather-inventory\translations\en_us.lua` |

Preserve deployed config.lua, all other resources, native-recovery-batch.json and native-acceptance-report.json. Do not copy .git, tests, development fixtures or this documentation. No UI build, MySQL resource change or full server restart is required. Refresh is required because the Inventory manifest lists a new internal script and there is a new service file.

## Commands and actions, in order

Server console before copying:

```text
InvNativeRecoveryBatch status
WeaponNativePrepareStopAll
WeaponNativeShutdownStatus
```

Require idle/cleared recovery and aggregate PASS with phase ready and completed=total. On refusal or failure, stop and retain the output. Then server console:

```text
stop feather-weapons
```

Fully quit both RedM clients. Copy the seven runtime files above. Server console:

```text
refresh
restart feather-inventory
restart bcc-stashes
ensure feather-weapons
```

Check Inventory startup has no schema/readiness error. Reconnect Jane and John once. No current numeric player IDs are needed. Server console:

```text
InvMoveRecoveryAcceptance
```

Requires the existing Config.DevMode=true. Expected one JSON report with phase passed, checks4, itemWrites0, automaticMutationRetries0 and four true observations (lostCallerReply, rollback, lateOriginalFenced, backgroundRecovered). The command is console-only, rejects overlapping invocation, and writes only diagnostic receipts/scopes after checking its sentinel inventory IDs do not exist. It never grants/moves items or kills connections. Caller acknowledgement loss and resolver outage are simulated around actual receipt SQL; the separately accepted wire tests establish transport behavior. On failure retain the output; do not blindly repeat.

One native UI round-trip: as Jane, open the existing test storage box, keep her test Lasso unequipped (use its Equipment panel to unequip first if necessary), move it into the box once, close/reopen to confirm one Lasso there and none with Jane, then move it back once and confirm one with Jane and none in the box. Do not grant a replacement. The fixture is item229, serial FW-LASS-6AE6BCBA-26771B-0001; item numbers need not appear in the UI. Check Jane's equipped firearms still draw and John's existing wheel remains unchanged. No SQL dumps, repeated maintenance logs, death/reconnect cycle or repeat of all eight utility tests is requested.

The earlier WeaponNativeAcceptance run1793599650:114993425 remains accepted complete3/3/visual pass. This deployment does not overwrite that report or require a repeat.

## Local verification

Inventory Lua runner passes all specs and 88 runtime syntax files, including engine restart/unknown/rollback/fence/provider-retry cases, actual SQL service wiring, four-step diagnostic command and original list/slot/split controller composition after lost commit acknowledgement. Inventory JS3 and Weapons Lua219/JS7 pass. These models are not live InnoDB concurrency, whole-database restart or RedM process-crash acceptance.
