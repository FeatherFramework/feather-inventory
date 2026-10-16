# Inventory 0.6.0 — alpha checkpoint PR

Prepared 2026-10-16. No commit/push/PR created. Admin was already submitted by
the user and is outside this preparation. Merge/deploy Inventory before Weapons
0.17.0. This checkpoint is test-server alpha, not a production-native cutover.

## Title

```text
feat(inventory): add guarded native weapon maintenance and attachment transactions
```

## Summary

```text
- Add canonical repair, attachment, evidence and final-wear transactions with revision and current-owner checks.
- Preserve equipment/ammo/material conservation across native lifecycle changes and rollback boundaries.
- Require explicit guard approval and prevent legacy equipment writes from bypassing native ownership.
- Improve equipment UI lifecycle handling and expose item revisions for Admin inspection.
- Add scoped development audit/fixture tools and regressions; bump Inventory to 0.6.0.
```

## Scope and boundaries

New transaction bodies and trusted exports compose final wear with equipment,
attachment or death changes through Inventory-owned SQL transactions. Weapons
owns native entity/session reservations; Inventory does not adopt client native
state as economic authority. Current/serial/revision/guard/equipment checks retain
fail-closed semantics. Inspection revision projection is SELECT-only.

Fixture/audit helpers are development-only/scoped, not a general grant API.
Audit snapshot files are ignored by Git and excluded from the release ZIP.
No database migration file or item-name change is introduced by this diff.
Existing CharacterAmmunitionEnabled stays false by default. Existing DevMode=true
is deliberately preserved for alpha testing, not production-hardening acceptance.

## Checks on 2026-10-16

- Full tests/run_lua.py PASS, including syntax for63 runtime/config/manifest files,
  transaction composition, rollback, explicit guards, fixtures and read projection.
- Two web lifetime Node tests PASS.
- pnpm --dir web check PASS (ESLint + production build).
- Runtime ZIP staging/allowlist/assets/version verification PASS through existing
  scripts/package_release.py. Local artifact `.artifacts/feather-inventory.zip`;
  checksum alongside it. Source changes do not track generated ui/ files.
- git diff --check PASS.
- Toolchain caveat: available Node24.19.0/pnpm11.25.0 warned against declared
  Node22/pnpm9.15.0. Build passed, but exact declared-toolchain CI remains useful.
- Transaction tests use mocked DB/resource boundaries; no new live SQL tests run
  this preparation. Previously accepted focused test-server results are recorded
  in framework docs. No concurrency/outbox/exactly-once guarantee inferred.

## Exact changed runtime deployment files

Repository `C:/coding/feather-scripts/feather-inventory`:

```text
fxmanifest.lua
client/services/nuicallbacks.lua
server/controllers/inventory.lua
server/services/character_ammunition.lua
server/services/character_ammunition_enrollment.lua
server/services/equipment.lua
server/services/guards.lua
server/services/native_equipment_commit.lua
server/services/transactions.lua
server/services/native_attachment_commit.lua
server/services/native_evidence_commit.lua
server/services/native_lifecycle_wear.lua
server/services/native_repair_audit.lua
server/services/native_repair_commit.lua
server/services/native_repair_fixture.lua
server/services/native_repair_verify.lua
ui/index.html
ui/assets/ (the complete matching generated build)
```

Do not deploy web/src, node_modules, tests, audit snapshots or docs as runtime.
For a full install use the verified package, preserving the server's config.lua.
For an update deploy the Lua files and matching generated UI atomically; do not
mix index.html with an older assets directory or remove custom item images.

New wildcard-loaded scripts and manifest version require server-console refresh.
While native Weapons is active: WeaponNativePrepareStop CURRENT_ID; wait for
PASS before stop feather-weapons. Deploy Inventory and Weapons together with
native host stopped, refresh, restart Inventory, restore dependent Admin/Shops,
then ensure Weapons. Do not restart Inventory underneath an active native owner.
No flag activation/config replacement required to merge this checkpoint.

## Remaining alpha work

Broader live contention/failure matrix, cross-owner law/custody, native destruction,
production probe cleanup and exact-toolchain CI remain follow-up work. Admin's
new UI visual/controller gate is separate; do not repeat economic tests solely
to accept presentation. Link the Weapons0.17.0 PR and already-submitted Admin PR
manually when creating these PRs; their URLs were not supplied in this chat.
