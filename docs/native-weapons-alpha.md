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
