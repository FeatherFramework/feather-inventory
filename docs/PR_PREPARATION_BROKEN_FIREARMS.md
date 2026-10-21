# Broken-firearm alpha companion to Weapons

Reviewed 2026-10-16 against local checkpoint e39ab25 / PR #52.
No commit, push or PR created. Version remains 0.6.0; no bump in this review.

## Proposed title

```text
feat(inventory): atomically detach broken firearms and promote healthy offhands
```

## Summary

```text
- Compose broken-equipment removal and compatible offhand promotion with wear persistence in one transaction.
- Keep death-time assignment writes bound to the reserved Weapons observation context.
- Roll back ammo, metadata and assignments together on guard, revision or authority failure.
- Advertise companion broken-equipment and promotion contracts for safe paired deployment.
- Add immutable named audit baselines and transaction-composition regressions.
```

## Verification and limits

Full Lua suite, 63 runtime Lua syntax files, 2 Node UI tests and diff checks pass.
Tests compose actual ammo/wear/equipment bodies using mocked DB transport; they
cover promotion veto rollback and funded/zero-ammo death observations. Live tests
accepted periodic shoulder break/recovery, synthetic death shoulder detachment,
and periodic mixed-sidearm promotion followed by repair/re-equip. Funded death,
death promotion, same-model promotion and complete independent conservation
audits remain deferred. See authoritative framework plans for acceptance evidence.

## Deployment

Deploy together with Weapons while Weapons is stopped after prepare-stop PASS.
Restart Inventory and affected dependents before starting Weapons. No new config,
migration, manifest change, refresh or UI build in this delta.

Runtime files changed since #52:

```text
server/services/character_ammunition.lua
server/services/conditional_equipment.lua
server/services/native_equipment_commit.lua
server/services/native_lifecycle_wear.lua
server/services/native_repair_audit.lua
```

Preserve all private .native-*-audit-*.json baselines on deployment. Optional audit
labels create separate immutable files; duplicate captures and unsafe labels are
refused. Do not ship private character audit snapshots in Git.
