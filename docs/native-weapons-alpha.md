# Shared ammunition and native equipment alpha

`Config.CharacterAmmunitionEnabled` remains false by default. This development
integration needs the matching scoped native Weapons host, Character logout
checkpoint fix and Medical client lifecycle adapter. It does not automatically
enroll characters, import legacy ammunition or enable native weapons for everyone.

Inventory owns economic SQL transactions: shared carried-pool snapshots and
revision checks, loose ammo transfer/observation receipts, explicit enrollment
and payload-bound one-time development grants. Native runtime tickets are
independently validated through Weapons before work and commit. Never issue a new
operation/grant key merely because a reply was lost.

Equipment writes use full expected equipment snapshots, owned item revisions,
existing instance guards and current acknowledged-release authority. Weapons
coordinates native sealing/cleanup/release before commit and fresh restore after.
Inventory does not pass transaction handles to the Weapons resource. Equipment
changes do not move, grant, consume or convert ammunition.

The own-item Equipment panel offers server-approved equip/unequip positions.
Ammunition shows loose/carried availability and permits conserved Load/Unload;
native wheel ammo selection stays in-game. Both panels invalidate stale replies
on lifecycle closure. An uncertain mutation is not an instruction to retry.

Live acceptance covers the scoped Cattleman primary roundtrip and completed-state
logout/relogin, with final item112 revision1/ledger21/carried0/loose2/receipts22.
In-flight lifecycle races, abnormal ownership recovery, multiplayer contention
and broad native family/slot testing remain separate. Fixed Jane commands and
fixture probes are development tools, not public grant/enrollment APIs.

## Local verification and deployment

Run `python tests/run_lua.py --lupa-dir <optional-lupa-install>` from this repo
with Lua 5.4 through optional lupa; it is a test dependency, not server runtime.
The aggregate checks syntax and transaction/guard/native UI/equipment contracts.
In `web`, run `node tests/ammoPanelLifetime.test.mjs`,
`node tests/equipmentPanelLifetime.test.mjs`, lint and the Vite build. Generation
tests exercise the helper, not a real browser or CFX runtime.

The generated `ui/` is git-ignored; build/package it from `web` when distributing
this PR. For code-only UI deployments, copy `ui/index.html` and `ui/assets`,
preserving unchanged `ui/images`. Deploy corresponding runtime files together;
new scripts require server `refresh` before restart. Do not ship test flags on or
represent the new native path as generally production-ready.

2026-11-06 sidearm controls: paired guns can Swap hands; selected Primary can Unequip both sidearms in one sealed equipment transaction. Per-instance attachments/wear stay with the item; no ammo mutation or chained UI requests. Lone Primary explains the Offhand dependency. Automated policy/authority/CAS/rollback/final-wear tests pass; live button, drawing and reconnect checks remain pending. This does not extend attachment model coverage beyond the accepted Cattleman pair.

2026-11-06 user accepted the initial sidearm buttons live, then requested a simpler Primary removal. Updated behavior (automatically tested, LIVE PENDING): Primary — Unequip removes only that gun and promotes the existing Offhand gun to Primary atomically, preserving instance metadata; replaces the earlier Unequip both action. Swap hands remains. Panel explains the promotion through player locale text/English fallback. Final-wear identity changes, stale assignments and insert/session failures refuse/roll back the operation. No migration or new runtime file. Preserve feather_native_guid_ownership=1 at server startup for worn same-model pairs.

2026-11-06 Primary removal/Offhand promotion LIVE ACCEPTED: user confirmed all requested checks worked. Primary — Unequip leaves the removed gun in inventory and promotes the existing Offhand to Primary; re-equipping the other gun restores two drawable Cattlemans. Final Jane runtime ACTIVE ownedCopies2, idle/non-quiescing/non-receiving, no pending/closing/deathClosing; epoch3e84efcc-da1a-11f1-9f05-e0d55eaa2deb:1793994260:262267:3. Maintenance128 rev10 retains permanent/degradation/damage0.10000000149011 and dirt/soot0;231 rev2 remains pristine. Ammo ledger35 unchanged, repeater regular1 and remaining pools0. This accepts the revised single-action Primary removal/promotion and re-equip sequence in the observed unequal-wear Cattleman pair. Earlier Swap hands live acceptance remains valid. No further deployment or repeated test required to record this gate; commits/PRs remain deferred. Broader model, customized-pair death and concurrency acceptance remain outside this result.

2026-11-06 cleanup update (automated, live restart pending): GUID ownership defaults1 consistently; explicit0 still refuses worn pairs. Temporary pair-options diagnostic is test-support-only and absent from runtime manifest. Use docs/equipment-installation.md for current scope; older commands/default0 notes above are historical. Configs and saved reports are preserved by the paired prepared batch. Accepted Cattleman/controls results remain valid; only fresh missing-convar startup and drawing require live confirmation.

2026-11-06 fresh-start GUID default LIVE ACCEPTED: user explicitly confirmed both Cattlemans draw and the restart completed without a feather_native_guid_ownership console command or startup entry. Jane ACTIVE ownedCopies2, idle/non-quiescing/non-receiving, ammo active with no pending/closing/deathClosing; new session f7852ffe-da27-11f1-9f05-e0d55eaa2deb, epoch1794000076:171756:1. Item128 revision10 preserves permanent/degradation/damage0.10000000149011 and dirt/soot0;231 revision2 remains pristine. Ledger35/repeater regular1 and all other pools0 unchanged. This completes the requested cleanup/default live startup and drawing gate for the observed pair. Earlier accepted equipment and attachment tests need not repeat. No additional deployment/restart/test requested; commits, version bumps and PRs remain deferred. Probe exclusion is verified by manifest/source tests; user supplied no separate live probe-command absence check, and none is needed for this startup/draw gate.
