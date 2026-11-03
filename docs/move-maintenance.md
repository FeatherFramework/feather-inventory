# Recovery retention and health — automatic maintenance

2026-11-02 LIVE recovery maintenance acceptance PASS. InvMoveMaintenanceAcceptance returned phase passed/checks9/retentionDays30, fixtureRollbackConfirmed=true, unresolvedPreserved=true, recentPreserved=true, activeScopesPreserved=true, oldSettledRemoved=true, health healthy, gameplayWrites0 and provenanceWrites0. The reported ROLLBACK (39 queries,2555ms) was the intentional diagnostic rollback, not a failed gameplay transfer. InvMoveHealth independently returned healthy, pendingMoves0, pendingDeliveries0, pendingRefreshes0, activeScopes0, all oldest ages0, automaticMutationRetries0 and weaponDeduplicationPolicy retain. Automatic cleanup reported phase complete/removed0/batchLimit25/retentionDays30. Removal of eligible diagnostic records was proved within the rolled-back acceptance transaction; do not claim real aged production rows were deleted (worker removed0). This accepts the live schema, cleanup predicate/transaction rollback/readback and health-report gate. No additional copy, restart, manual SQL or repeat functional testing required for this batch. Required receiver deduplication/provenance remain retained. Whole database/RedM process restart/crash recovery and arbitrary third-party acknowledged delivery remain outside this accepted scope.

Implemented, locally verified and LIVE accepted 2026-11-02.

## Behavior and design boundaries

No configuration or manual database migration is required. Startup adds Inventory completion/delivery timestamps and a cleanup index. A worker runs every minute, initializes up to100 legacy timestamp rows per table/pass with a NEW grace period and processes at most25 eligible operation pairs per pass. Thirty days is a minimum retention period, not an exact deletion deadline under load.

Cleanup requires an outcome settled at least30 days ago, completed recipient refresh, no active scope, and (for commits) an outbox delivery acknowledged at least30 days ago. Rollbacks require no outbox row. Candidates exclude protected work before the bounded page is selected, avoiding a page of unresolved records starving later eligible rows. Each candidate is locked and rechecked in scope->outcome->outbox order; outcome and outbox deletion share one transaction. Pending work, unacknowledged delivery, pending refresh, recent outcomes, recent deliveries, and active scope reservations remain protected. Committed historical records without an outbox are retained conservatively.

Weapons provenance and receiver deduplication receipts remain intact, including their payload checks/event IDs: deleting those receipts could allow a delayed old callback to create a duplicate ledger entry. Saved acceptance reports, gameplay inventory/items/equipment/ammunition, and idle scope rows are not pruned. This is Inventory recovery-payload retention, not a promise to remove every framework audit or receipt. No automatic economic replay or guessed repair is introduced. Unknown cleanup acknowledgements can safely be read again on the next worker pass.

The health worker is quiet while unchanged/healthy; attention, unavailability and recovery transitions emit a short console message. InvMoveHealth performs fresh read-only checks and reports healthy, waiting, attention or unavailable, pending outcome/delivery/refresh counts and oldest ages, active scopes, retention policy and last cleanup result. Pending work older than60 seconds, orphan-looking active scopes, or failed cleanup require attention; temporary work reports waiting. These are service diagnostics, not proof of every framework dependency or whole-DB/RedM crash acceptance. All new messages are console-only; player language contracts are unchanged.

## Required runtime files

Copy only these three files (no Weapons runtime change):

| Absolute local source | Absolute server destination |
| --- | --- |
| `C:\coding\move-maintenance-deploy\feather-inventory\server\services\move_maintenance.lua` | `C:\Servers\redm_feather\server\resources\[feather]\feather-inventory\server\services\move_maintenance.lua` |
| `C:\coding\move-maintenance-deploy\feather-inventory\server\services\move_recovery.lua` | `C:\Servers\redm_feather\server\resources\[feather]\feather-inventory\server\services\move_recovery.lua` |
| `C:\coding\move-maintenance-deploy\feather-inventory\server\services\move_outbox.lua` | `C:\Servers\redm_feather\server\resources\[feather]\feather-inventory\server\services\move_outbox.lua` |

Preserve configuration, reports and other resource files. Documentation/tests remain local and are not required runtime files. Refresh is required because the Inventory service file is new, even though its existing manifest glob loads it. No UI build, manual SQL, new convars or full server restart is required.

## Complete deployment and acceptance

Server console before copying:

```text
InvNativeRecoveryBatch status
WeaponNativePrepareStopAll
WeaponNativeShutdownStatus
```

Require recovery idle/cleared, aggregate PASS, shutdown ready and completed=total. Retain failures rather than bypassing a refusal. Server console:

```text
stop feather-weapons
```

Fully quit both RedM clients. Copy the three runtime files above into Inventory, retaining their folder paths. Server console:

```text
refresh
restart feather-inventory
restart bcc-stashes
ensure feather-weapons
InvMoveMaintenanceAcceptance
InvMoveHealth
```

Check startup has no schema/readiness error. The existing Config.DevMode=true is required only for the acceptance command. Both commands are server-console-only; no player IDs or active clients are needed. You may reconnect both clients after the checks. No gameplay movement, Lasso round-trip, grant, death cycle, SQL dump or utility draw retest is requested for this batch.

Expected acceptance: phase passed/checks9, retentionDays30, oldSettledRemoved/unresolvedPreserved/recentPreserved/activeScopesPreserved/fixtureRollbackConfirmed true, gameplayWrites0/provenanceWrites0. It inserts eight isolated diagnostic receipts, tests the REAL cleanup predicate/deletes inside a transaction deliberately returning false, then independently confirms none of its receipt/outbox/scope assignments survived. It tests two eligible removals and preservation of pending/recent/pending-delivery/pending-refresh/recent-delivery/active-scope cases, plus rollback/readback and health. It never invokes cleanup of real aged records as a test action. The normal worker will independently maintain real eligible records after startup.

Expected health: healthy (or waiting while short-lived work settles). If waiting, allow a few seconds and rerun ONLY InvMoveHealth. If attention, unavailable or review_required appears, retain the report for inspection; do not repeat transfers, delete receipts, or run manual repair SQL. Send the acceptance output and health report. No repeat of previously accepted functional gates is required.

## Local verification

Inventory full Lua suite passes with90 runtime syntax files, three JS checks and Weapons220 Lua compatibility specs. Maintenance tests exercise schema migration wiring, rollback-only nine-check console acceptance, actual cleanup transaction wiring against a storage model, lost cleanup acknowledgement, fresh upgrade grace, protected pending/recent delivery/refresh/scopes, and healthy/waiting/attention/unavailable reports. Tests assert no gameplay item, provenance or receiver-receipt SQL. Live MariaDB schema/transaction validation remains pending until the command above passes; no whole server/database crash claim is made.
