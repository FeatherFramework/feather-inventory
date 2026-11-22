# Inventory 0.18.0

Release preparation; not yet published. Pair with Weapons0.26.0; Shops0.5.0 is
unchanged. Cross-link the Weapons and Inventory PRs. User handles all git/PR and
release actions. After review and green paired CI, publish Inventory first, then
Weapons, and coordinate deployment of both runtime changes.

- Record paid Regular-knife debits and consume their bounded recovery allowances
  atomically with the character ammunition ledger.
- Convert paid Poison-knife debits into once-only Regular recovery allowances.
  Distinct source receipt IDs avoid same-revision collisions; retain source/type
  audit fields, same-bucket, 50-metre and180-second limits and deterministic locks.
- Preserve other ammunition pools and real shot reductions during partial claims;
  roll back receipts and balances together on persistence failure.
- Decline unconfirmed specialty-arrow/Poison-to-Poison increases without saving
  unfunded units. Existing regular recovery namespaces remain isolated.
- Refuse conflicting legacy equipped knife carriers without automatic migration.

Use the five replicated startup flags documented in Weapons0.26.0 release notes.
Preserve existing schema, item names, historical serialized items, configuration
and prices. No SQL migration, grants, automatic mutation retries or item refunds.

Validation: full Inventory Lua suite with actual debit/claim primitives against
modeled SQL, including same-revision conversion receipts, once-only claims,
capacity/proximity/expiry/bucket checks and atomic rollback. Paired Weapons checks
and Jane live results cover Regular shared recovery, Poison own conversion,
specialty consumption/transfers/reselection and loaded death/revive/restart.
No live competing-collector contention or specialty-arrow recovery is claimed.

Both fxmanifest.lua and web/package.json are0.18.0. The existing release workflow
must verify/build the tagged source and attach the verified archive/checksum.
Pushed implementation heads are verified: Inventory
f589667aa92fb3d545444ed9897f18a678f0dbba and Weapons
4c95245506bfbe4d4580f537b88eb391c7ed27f5. Local workflow follow-ups select these
exact paired sources; user commit/push and fresh green CI remain required.
