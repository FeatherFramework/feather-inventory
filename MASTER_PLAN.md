# Feather Inventory — Master Plan

> Status: proposed hardening & completion plan — two parallel tracks: unblock `feather-weapons` (§7), and finish inventory's own features on their own merits (§10)
> Compatibility policy: the framework is alpha — breaking the current API is acceptable when required by [`DEPENDENCY_SUPPORT_PLAN.md`](./DEPENDENCY_SUPPORT_PLAN.md) §4's target contracts; changes should still preserve unrelated consumers where practical, not break things gratuitously
> Source of truth: an `inventory_items` row is the ownership record; per-instance state moves to a versioned metadata document (§7) — flat `item_metadata` key/value rows are retained only as a compatibility projection if still useful
> Primary rule: the server owns every inventory mutation, including *where in the UI grid* an item sits (`slot_index`) — already true today (§2), including capacity/weight enforcement on every grant and transfer path

## 1. Purpose

`feather-inventory` is the item/ownership domain the rest of the Feather ecosystem builds on, and it is under active, fast-moving development in its own right — a slot-based "steampunk ledger" UI, a robbery/forced-search access model, and real weight enforcement have all landed since this plan was first drafted. This document tracks two things that are both real priorities, not one subordinate to the other: what `feather-weapons` needs from this resource (§7, `DEPENDENCY_SUPPORT_PLAN.md` §4), and what inventory needs to finish being a complete, polished system on its own terms (§10). Neither blocks the other; they're sequenced to run in parallel.

## 2. Where things actually stand

`feather-inventory` has been through a long-running security/consistency audit — the original framework-wide Phase 1–6 pass (`AUDIT-FRAMEWORK-SUMMARY.md`, findings `INV-01` through `INV-10`), and a second wave of findings (`INV-11` through at least `INV-23`, plus an unlabeled "Tier 1 audit sweep" and several small bugfix commits) that closed real gaps discovered while building the newer features below. All of it is closed and referenced inline at its fix site — this plan doesn't re-enumerate every ID, but the shape of what's already solid matters for sequencing what's left:

- **Ownership is enforced at the row level and re-verified live, not just at open time.** `IsInventoryAccessibleBySrc` re-checks proximity/status for a robbery target on every subsequent move, not just when the inventory was first opened (`INV-11`/`INV-23`).
- **A real access-control model exists**, not just "your own inventory or nothing": owned/shared inventories (storage, saddlebags, job lockers) via `owner_character_id` + a persistent `inventory_access` grant table; public inventories (ground piles) via an `is_public` flag; player-to-player robbery/forced-search via proximity *and* a status check. All three are in `server/services/inventory_access.lua`.
- **Weight and capacity are actually enforced on every transfer path** — `MoveInventoryItems` (which `UpdateInventory`, `GiveItem`, `DropItemsOnGround`, and the ledger's `MoveItem` all funnel through) calls `InventoryCanHoldById` before committing. This was itself the subject of several fixes (`INV-14`, `INV-10`) — earlier versions of this check silently no-op'd.
- **A slot-based UI replaced the old panel design.** `inventory_items.slot_index` is real, persisted grid placement; `GetJoinableSlot`/`GetFreeSlot`/`GetItemsInSlot`/`MoveSlotItems` implement "join an under-full stack, else claim a free compartment" server-side (previously faked client-side with lodash). Drag-to-empty moves, drag-to-occupied swaps.
- **SQL-identifier injection in `RegisterForeignKey`/`RegisterInventory` is closed** (`INV-18`) — table/column names from other resources are now validated against a strict identifier pattern before being concatenated into DDL.
- **A trusted `ItemsAPI.GrantItem` export exists** for admin/reward/scripted flows — validates quantity, catalog membership, slot capacity, *and* weight atomically, returning structured `{error, code, message}` results (a better contract than the older `ItemsAPI.AddItem`, see §6).

This plan starts from all of the above as given. What's left is real but narrower than it was: closing the one remaining weight-enforcement gap, finishing what the robbery system needs from `feather-core` to actually turn on, and the UX/feature backlog in §10.

## 3. Non-goals

- Re-litigating any closed `INV-xx` finding.
- Re-deriving character/ownership binding — `feather-core`'s job, consumed correctly today.
- Building weapon-specific rules into inventory — stays generic per `DEPENDENCY_SUPPORT_PLAN.md` §4.1.
- Abandoning the ledger's book-page visual identity (frame art, header, category tabs, footer) — that chrome stays static and fixed-size. What's no longer a non-goal: the *compartment grid* inside that chrome scrolling to hold more than fits on one visible page (see §10.4, now a resolved direction rather than an open question).
- Preserving the current inconsistent return shapes as a constraint — already being cleaned up incrementally (`GrantItem`'s `{error, code, message}` is the better pattern; older functions still return bare `false`/`nil`/`-1`).

## 4. Guiding principles

1. **`DEPENDENCY_SUPPORT_PLAN.md` §4 is the authoritative weapons-support target**, sequenced by this plan, not softened by it.
2. **Inventory's own feature completeness is not "extra credit."** README's TODOs and the ideas in §10 get real phases and real priority, not a leftover slot after weapons work.
3. **Breaking changes are allowed, gratuitous ones aren't** — alpha framework, but a change still needs a reason.
4. **Server authority, always** — every mutation, including grid placement, re-derives identity from `src`; the robbery system is the clearest recent example (proximity *and* status, both re-checked live, neither trusted from a lock alone).
5. **A half-finished feature is worse than a missing one.** The robbery/ACL system is fully built server-side and currently inert because `feather-core` doesn't implement `Feather.Character.HasStatus` yet — that's called out explicitly in §6/§10 as the highest-leverage single unblock available, not left as an implicit gap.

## 5. Current architecture (as-built)

```text
UI (Vue3, local reactive() state -- no Pinia) ── "steampunk ledger": LedgerBook.vue (grid) / ContextMenu.vue (Use/Give/Drop) / ItemCountModal.vue (partial qty)
       │  NUI callback
       ▼
client/services/nuicallbacks.lua  (thin forward, no logic)
       │  Feather.RPC.CallAsync
       ▼
server/services/callbacks.lua  (RPC surface — GetInventoryItems, UpdateInventory, GiveItem, MoveItem, GrantAccess/RevokeAccess/SetPublic/ListAccess, GetCategories, GetCharacterInfoForDisplay)
       │
       ▼
server/services/{inventory,items,categories,ground,character,commands,inventory_access}.lua   (InventoryAPI / ItemsAPI / CategoriesAPI)
       │
       ▼
server/{controllers,services}/slots.lua + controllers/{inventory,item,ground,categories}.lua   (raw MySQL — inventory/inventory_items/item_metadata/items/categories/inventory_blacklist/ground/inventory_access)
```

Public surface today, exported via `exports['feather-inventory'].initiate()`:
- `InventoryAPI` — `RegisterForeignKey`, `RegisterInventory` (now takes `ownerCharacterId`/`isPublic`), `InventoryCanHold`/`InventoryCanHoldById`, `InternalOpenInventory`, `IsInventoryAccessibleBySrc`, `OpenInventory`, `CloseInventory`, `GetInventory`, `GetCustomInventory`, `GetInventoryItems`, `InternalCloseInventory`, `GetInventoryOwner(AndVisibility)`, `Grant/Revoke/List InventoryAccess`, `SetInventoryPublic`, `Grant/Revoke/HasTemporaryAccess`
- `ItemsAPI` — `GetDefinitions`, `GrantItem` (new, trusted, atomic), `AddItem`, `RemoveItemByName`, `RemoveItemById`, `SetMetadata`, `GetItem`, `GetItemCount`, `ItemExists`, `InventoryHasItems`, `RegisterUsableItem`, `UseItem`, `DropItemsOnGround`
- `CategoriesAPI` — `GetCategories`
- RPCs additive since the last version of this plan: `Feather:Inventory:MoveItem` (slot drag/swap), `Feather:Inventory:SplitStack` (peel part of a stack into a free compartment, same inventory), `Feather:Inventory:GrantAccess`/`RevokeAccess`/`SetPublic`/`ListAccess`
- Events: `feather-inventory:ItemAdded`, `feather-inventory:ItemRemoved` (unchanged contract, still what `feather-weapons` listens to)

Schema additions since the last version of this plan: `inventory.owner_character_id`, `inventory.is_public`, `inventory_items.slot_index`, `inventory.max_slots`, the `inventory_access` table — all self-migrated at startup the same way `RegisterForeignKey` always has (`SHOW COLUMNS` + conditional `ALTER TABLE`), never touching `feather-recipe`'s own migration.

`Config.maxItemSlots` is now the *default* capacity rather than a global physical limit — `config.lua`'s comment was updated alongside §10.4 so it no longer describes the pre-scroll state.

## 6. Residual issues found in the current code (not yet tracked elsewhere)

**Found 2026-08-21, partially fixed 2026-08-21, fully closed 2026-08-23:** `Feather:Inventory:MoveItem` (the ledger's drag-and-drop RPC, `server/services/callbacks.lua`) called `InventoryControllers.MoveSlotItems` directly — raw `UPDATE inventory_items` statements with no weight/capacity check — while every other movement path (`UpdateInventory`, `GiveItem`, `DropItemsOnGround`) routes through `MoveInventoryItems` → `InventoryCanHoldById` first.

The 2026-08-21 pass could only close the empty-destination half, by reusing `InventoryCanHoldById`. The occupied-slot swap was left deliberately open because that helper is addition-only: its "add this on top of the inventory's current total" model double-counts the stack simultaneously leaving `fromInventory` to make room for the swap, and bolting it onto swaps would have produced *false rejections* rather than merely weak ones.

**Now closed.** `InventoryAPI.EvaluateSlotMove` (`server/services/inventory.lua`) replaces it with real net-delta math — `(current − leaving) + arriving` — evaluated for **both** inventories. Three things fell out of doing it properly:

- The **swap's return leg was entirely unchecked**, and that was the more serious half. Even the empty-slot fix only ever validated the destination; nothing verified that what came *back* to the source inventory was affordable to it. A near-full inventory could receive an arbitrarily heavy occupant stack.
- Slot capacity is deliberately *not* re-checked here, unlike a grant: `MoveItem` targets one specific compartment index already bounds-checked against capacity, so no new compartment is ever claimed beyond the one named. Weight, per-item quantity, and the blacklist are the real constraints.
- The empty-destination case is no longer special-cased at all — it is the degenerate "nothing is leaving" form of the same calculation, so both paths now share one code path instead of two divergent ones.

Verified by simulation across four cases: a swap at the weight limit trading equal weights is correctly **allowed** (the addition-only model wrongly rejected it), a genuinely overloading swap is rejected on the destination side, a swap whose return leg overloads the source is rejected on the source side (previously allowed), and an empty destination degrades to the pure-addition result.

**Found 2026-08-23, fixed 2026-08-23: the resource carried four mutually-inconsistent definitions of "full".** Surfaced by a reported bug — an apple with `max_quantity=100` and `max_stack_size=20` refused the 21st apple in the whole inventory. Root cause was not one bug but a systematic conflation of *stack size* (a per-compartment placement property) with *quantity limit* (an inventory-wide acceptance limit), plus two independent arithmetic errors:

- `AddItem` compared the inventory-wide count of an item against `max_stack_size` — the reported bug.
- `GrantItem` used `math.min(max_quantity, max_stack_size)`, the same conflation by a different route. This is the path `feather-admin`'s give-item flow calls, which is how it was hit.
- `GrantItem` also compared total unit *count* against `Config.maxItemSlots`, treating each unit as consuming its own compartment — 25 apples stacked into 2 slots reported a full 25-slot book.
- `InventoryCanHold`/`ById` had the quantity check right but summed weight without multiplying by quantity, so moving 10 apples only ever counted one apple's weight. This partly undercut §2's "weight is actually enforced on every transfer path" claim — it was enforced, but under-counted on every multi-unit move.
- The same `ignore_item_limit` column was read three different ways (`== 0`, `tonumber(x) ~= 1`, `Boolean[x]`). All three happen to work because the column is `tinyint(4)` and comes back a number — but `is_public` is `tinyint(1)` and comes back a real boolean, which is exactly how that flag silently read as `false` for every public inventory until `Boolean` gained `[true]`/`[false]` entries. Same latent trap, one column-width change away.

All five now route through one `EvaluateInventoryAcceptance(inventory, maxWeight, ignoreItemLimit, items)` in `server/services/inventory.lua`, which is the sole definition of whether an inventory can accept N of something. `InventoryCanHold`/`InventoryCanHoldById` are thin wrappers over it; `AddItem`/`GrantItem` call it directly. Two behaviour changes fell out of the consolidation: `GrantItem` now respects the per-inventory blacklist (it previously skipped `IsItemRestricted` entirely, so an admin could grant an item into an inventory explicitly barred from holding it — this adds one new error code, `item_restricted`, and a matching `feather-admin` locale key), and `AddItem` no longer reports success on a partial grant when it runs out of slots mid-loop.

This is also the prerequisite for §10.4: `GetFreeSlot(inventory, capacity)` and the acceptance check now read capacity from one place, so making it per-inventory is a change to one helper rather than to four divergent call sites.

- ~~**`ItemsAPI.AddItem` doesn't enforce weight.**~~ **Fixed.** `AddItem` now resolves the inventory's `maxWeight` and the item's weight and rejects before granting, same unconditional-of-`ignore_item_limit` pattern as `GrantItem`/`InventoryCanHoldById`.
- ~~**`GiveItem` has no server-side distance check between giver and recipient.**~~ **Fixed.** `Config.Access.GiveDistance` + `IsWithinGiveDistance` (same shape as `IsWithinRobberyDistance`, separate config value since giving is consensual, not forced-search) now gate the RPC.
- ~~**Debug `print(("[DEBUG-GROUND] ..."))` calls are still live in production paths**~~ **Fixed.** All five (across `inventory_access.lua`, `inventory.lua`, `ground.lua`) now route through a new `DebugPrint(tag, fmt, ...)` helper (`server/helpers/main.lua`) gated behind a new `Config.Debug` (default `false`, separate from `Config.DevMode`).
- **The robbery/forced-search system is fully built and currently inert.** `CanBeLootedDueToStatus` calls `Feather.Character.HasStatus`, which doesn't exist in `feather-core` yet — the function defensively (and correctly) fails closed, so the feature just does nothing right now. This is the single highest-leverage unblock available: the inventory-side work (proximity, status gate, live re-verification, temporary grants) is *done*; it needs exactly one thing from `feather-core` to go live. Worth raising with whoever owns that resource's roadmap directly, not just noting here.
- ~~**Stack splitting isn't possible.**~~ **Fixed 2026-08-23.** A `Split` entry now appears in the context menu for any compartment holding more than one unit, reusing the existing quantity modal and moving the chosen amount into the first free compartment of the same inventory (`Feather:Inventory:SplitStack` → `InventoryControllers.SplitSlotItems`). Deliberately same-inventory only: splitting *across* inventories would be a capacity-affecting transfer, which belongs on the `MoveItem`/`EvaluateSlotMove` path rather than duplicating that logic here. Dragging stays all-or-nothing, so the two gestures don't overlap.

## 7. Supporting feather-weapons (target contract from `DEPENDENCY_SUPPORT_PLAN.md` §4)

Full detail lives in `DEPENDENCY_SUPPORT_PLAN.md` — summary this plan sequences against, updated for what's already true:

**Item definitions.** Add explicit `instance_mode` (`stack`/`unique`); enforce quantity 1 on unique rows. *Already partially true in effect* — every granted unit is already its own row with its own `slot_index` and independent metadata; formalizing `instance_mode` mainly means blocking a unique item from ever joining a slot via `GetJoinableSlot`.

**Item instances.** A normalized read (instance ID, definition, container, slot, metadata document + revision) — not yet built; today's reads return the raw joined row shape.

**Metadata.** An atomic, versioned document replacing one-key-at-a-time `item_metadata` writes — not yet built. `ItemsAPI.SetMetadata` still loops key-by-key with no transaction wrapper.

**Transactions and locks.** A server-only `Inventory.Transaction(context, fn)` API with deterministic multi-item locking and revision-based compare-and-set — not yet built. `MoveSlotItems`/`MoveInventoryItems` do their capacity check-then-write as separate steps today, same race shape as before.

**Idempotency and guards.** Idempotency keys, item-instance leases, and a pre-move guard registry (so weapons can force an authoritative unequip before an equipped item moves) — not yet built.

**Events.** Structured post-commit events (`ItemCreated`/`ItemMoved`/`ItemMetadataChanged`/`ItemDestroyed`/`TransactionCommitted`) — not yet built; `ItemAdded`/`ItemRemoved` remain the only signal, now also fired correctly from `MoveItem` (slot drag) when an item actually changes inventory, not on in-place rearrangement.

**Container access.** A generic `CanAccessInventory(source, inventoryId, action, context)` — partially superseded in spirit by `inventory_access.lua`'s purpose-built model (ownership/grant/public/robbery), but that model is bespoke to inventory's own RPCs, not exposed as a generic decision function other resources can call. Worth deciding whether weapons should call inventory's real ACL directly rather than inventory building a second, more generic layer on top of it.

## 8. Concurrency and locking

Unchanged from the prior version of this plan: `OpenInventories` locks a non-owned inventory to one `src` while open; no lock on concurrent mutation of the same inventory across RPCs, no transaction wrapping multi-step sequences. Superseded by §7's transaction API once it lands (`INV-W2`) — don't build a standalone mutex now.

## 9. Security posture

Better than the last version of this plan gave it credit for:

- **`DropItemsOnGround`'s position is now bounded server-side** (`INV-17`) — the drop must be within `Config.Dropped.PromptViewDistance + 1.0` of the caller's own server-cached position. The earlier version of this plan flagged client-supplied drop coordinates as an open risk; that's closed.
- ~~**`GiveItem` still has no equivalent check**~~ **Fixed** — see §6.
- **RPC-level rate limiting** remains a `feather-core` concern; no evidence inventory needs its own limiter.
- **The robbery system's fail-closed default is correct and worth preserving** as a pattern: when a dependency isn't ready, the safe behavior is "the feature does nothing," never "the feature falls back to an unsafe default."

## 10. Inventory-native feature completion & product ideas

This is deliberately a first-class section, not an appendix to the weapons work. It's organized into three tiers: finishing systems that are *already half-built* (highest leverage, lowest new-design risk), the README's own stated backlog (already scoped, just not done), and new ideas worth considering.

### 10.1 Finish what's already started

- ~~**Unify the capacity model (§6).**~~ **Done.** One `EvaluateInventoryAcceptance` is now the only definition of "can this inventory accept N of this", replacing four inconsistent ones. Fixes the reported "can't hold more than 20 apples" bug at its root rather than at the one call site that surfaced it.
- ~~**`MoveItem` weight/capacity bypass (§6).**~~ **Done.** Both halves closed — `EvaluateSlotMove`'s net-delta math covers the occupied-slot swap and subsumes the empty-slot case, and it also closed the swap's return leg, which no version of this check had ever validated.
- **Unblock the robbery system.** As §6 describes, this is entirely inventory-side complete and blocked on one `feather-core` capability (`Feather.Character.HasStatus`). Raising this with the `feather-core` owner is higher-value than almost anything else in this plan — a fully-built feature sitting inert is the most wasteful possible state for it to be in.
- ~~**`AddItem` weight parity.**~~ **Done.**
- ~~**`GiveItem` distance check.**~~ **Done.**
- ~~**Split-stack action.**~~ **Done.** `Split` in the context menu (shown only for a compartment of >1), reusing the existing quantity modal, capped at one below the stack size — moving the whole stack out would leave an empty compartment behind, which is a move, not a split. The server enforces that cap itself rather than trusting the UI's, re-derives the inventory from the item's own row, and re-reads the stack from the slot instead of trusting which specific row ids the client picked.
- ~~**Surface rejection reasons in the UI.**~~ **Fixed.** Confirmed the gap was real — `App.vue`'s `onDrop`/`performDrop`/`performGive` only ever `console.log`'d rejections, nothing reached the player in-game. Server-side handlers (`UpdateInventory`, `MoveItem`'s access checks, `GiveItem`, `DropItemsOnGround`) now call `Feather.Notify.RightNotify(src, message, 3000)` on every rejection branch, reusing the exact call this codebase already makes elsewhere (`GetGroundUID`'s proximity check) — no new NUI/client wiring needed, confirmed via `feather-core/client/services/notifications.lua` that this is purely a server→client event today. Deliberately did **not** add this to `MoveItem`'s "Invalid move"/"Item not found"/"not placed" branches — those are defensive-only guards not reachable through normal drag-and-drop, adding a notify there has no real player-facing value.
- ~~**Debug print cleanup.**~~ **Done.**

### 10.2 README's stated backlog (already scoped)

- ~~**Ground item LOD**~~ **Fixed.** Turned out worse than "no culling" — the old `UpdateGroundLocations` handler unconditionally despawned and respawned *every* pile on the map for *every* online player on *every single* drop/pickup/empty event anywhere on the server, not just once at load. Rewrote `GroundItems` from an array to an id-keyed table, reconciled in place on updates (only piles that actually appeared/disappeared touch their entity), and added a 1s-tick LOD thread that spawns/despawns each pile's prop based on the player's own live distance (`Config.Dropped.LoadDistance`, new, validated `>= PromptViewDistance` in `errors.lua`). The pickup-prompt loop's `ipairs`-over-array logic and unguarded `item.entity:GetObj()` had to move to `pairs` + a nil-entity guard to match the new keying.
- **Hotbar** — still no server or UI implementation. §10.4's scrollable-grid decision gives this a cleaner answer than before: the hotbar can be the always-visible first page of compartments rather than a wholly separate strip, once scrolling exists as a concept in the UI at all.
- **Locale migration** — server/UI strings still hardcoded.
- **Frontend state management** — checked 2026-08-23: Pinia is **not** a dependency and is not referenced anywhere in `ui/src`. It was dropped during the Vite migration, so this item is "adopt a store layer if the ledger's `reactive()`-based local state in `App.vue` outgrows it", not "finish a half-done migration". No evidence it has outgrown it yet.
- **Shift+drag bulk transfer/drop** — not confirmed done; the quantity modal covers "choose a partial amount," but a shift-modifier that skips the modal and acts on the whole stack isn't visible in what's been built so far.

### 10.3 New ideas

Grounded in what's already built (slot-based ledger, generic custom-inventory API, per-item metadata, RDR setting) rather than invented from nothing:

- **Item condition/durability as a first-class, generic concept.** `item_metadata` already supports arbitrary per-instance state; a documented `condition` (0–100) convention with UI wear-stage icons (pristine/worn/damaged) would benefit weapons directly (`DEPENDENCY_SUPPORT_PLAN.md` wants exactly this) *and* every other degradable item — tools, clothing, saddlery. Doing this once, generically, in inventory is strictly better than every consumer resource inventing its own condition field.
- **Perishable/spoilage items.** Fits the README's own "realistic and immersive" pitch and the RDR setting particularly well: a `spoilsAt` metadata timestamp on food/consumables, a spoiled state that changes the item's usable behavior (or swaps it for a "rotten" item) once passed. Reuses the metadata system that already exists; no new subsystem, just a convention plus a periodic check (or lazy check-on-read, cheaper than a poller).
- **Vehicle/mount containers using the existing custom-inventory API.** `RegisterForeignKey`/`RegisterInventory` already generalize to "any entity with an ID" — horse saddlebags and wagon storage are concrete, comparatively low-effort applications of an API that's already built but has no in-game entity wired to it yet. This is closer to "plug in the existing generic system" than "build a new feature."
- **Quick-loot / "Take All."** Especially valuable once the robbery system goes live (§10.1) — a forced search that requires dragging items one at a time undercuts the tension the feature is going for. A single server-validated "move everything from this inventory to mine, respecting my capacity" action reuses `MoveInventoryItems`'s existing per-item validation, just called in a loop server-side instead of once per drag.
- **A visible weight/capacity meter in the ledger UI.** Weight is now actually enforced (§2) but nothing in the UI surfaces current weight vs. limit the way slot count is already shown — players can only discover the limit by hitting it. Low effort, meaningfully closes the "why did that just get rejected" gap even before §10.1's "surface rejection reasons" lands.
- **Search/filter within a book.** Less urgent for the 25-slot player book, but a real usability need for larger custom inventories (storage, wagons) once those exist in numbers — a text filter across the currently-visible book's items, no new backend needed.
- **A generic admin inventory-inspection export.** `feather-admin`'s own dependency-plan section (`DEPENDENCY_SUPPORT_PLAN.md` §7) wants weapon-specific admin tooling; underneath that, inventory itself should expose a read (and permission-gated write) path for "show me this online character's inventory contents" independent of whether weapons exists at all — useful for support/moderation on day one.
- **Sound/haptic feedback on pickup/drop/use.** Matches the "immersive" framing in the README's own pitch; currently unclear whether this exists — worth a quick audit before treating it as new work.

### 10.4 Per-inventory capacity — ~~resolved direction~~ **shipped 2026-08-23**: scrollable grid, static chrome

Earlier drafts of this plan flagged "per-inventory slot count override" as blocked by the ledger's fixed 574×983 book art. Decision: keep the book frame, header, category tabs, and footer exactly as they are (fixed-size, no redesign) and make only the compartment grid inside that frame a scrollable region. This resolves the capacity problem without a second art asset per size tier and without abandoning the ledger's visual identity — README's own "Add Inventory specific slot counts" backlog item (§10.2) is this, not a separate piece of work.

**Delivered.** The grid *region* is pinned to exactly one page's height (475px, 430px paired) with `overflow-y: auto` and `grid-auto-rows`; the chrome around it never moves. Capacity below one page deliberately leaves the rest of the page blank rather than shrinking the region — the art underneath doesn't resize either way. Scrollbar is styled thin/ink-on-parchment so it doesn't read as a browser widget sitting on an 1899 ledger.

Server side, `inventory.max_slots` (nullable, `NULL` = use the Config default, so no data migration was needed) is resolved through one `InventoryControllers.GetInventoryCapacity`, and every allocation and bounds check now goes through it: `EvaluateInventoryAcceptance`, both grant paths' `GetFreeSlot` loops (hoisted out of the loop, since capacity is a DB read now), `MoveInventoryItems`' target-slot assignment, `SplitStack`'s free-slot lookup, and `MoveItem`'s upper bound. That last one moved *after* the access checks rather than sitting with the cheap shape validation, so an unauthorized caller can't probe an arbitrary inventory's size.

`RegisterInventory` gained a 9th `maxSlots` parameter, written only when explicitly passed — omitting it on a re-register must not silently reset a container that was already given a custom size back to the default, same rule the `ownerCharacterId`/`isPublic` flags already follow.

Verified: the migration applies to the dev schema and is idempotent, `NULL` and explicit values both round-trip, both `RegisterInventory` INSERT paths execute with correct column alignment (checked in a transaction and rolled back), and the UI builds and lints clean.

What this took:

- **Frontend (`LedgerBook.vue`).** Wrap the grid cells in a scroll container sized to show one page's worth of compartments (still reads as "a page of the book") with `overflow-y: auto` for additional rows beyond that; the book-frame image, title/subtitle, category tabs, and footer label stay outside the scroll container and don't move. Drag-and-drop, hover highlighting, and the context menu need to keep working against scrolled-out-of-view slots (drop targets below the fold), not just visible ones.
- **Config/schema.** `Config.maxItemSlots` stops being the single number that *is* the grid's physical capacity and goes back to being a default. Capacity becomes a real per-inventory value the same way `maxWeight`/`ignoreItemLimits` already are — `RegisterInventory` gains a capacity parameter, self-migrated the same way `owner_character_id`/`is_public`/`slot_index` were (a nullable `inventory.max_slots` column, `SHOW COLUMNS` + conditional `ALTER TABLE`, falling back to `Config.maxItemSlots` when null).
- **Backend — smaller lift than it looks.** `GetFreeSlot(inventory, capacity)` already takes capacity as a parameter rather than assuming a global constant; every current caller just happens to always pass `Config.maxItemSlots`. Once capacity is per-inventory, callers pass that inventory's own registered capacity instead. `MoveItem`'s bounds check (`toSlot >= capacity`) needs the same swap. The slot-allocation logic itself (`GetJoinableSlot`, `GetItemsInSlot`, `MoveSlotItems`) is capacity-agnostic already and needs no changes.
- **Client payload.** `App.vue` currently reads one global `data.maxSlots` for both the player and "other" book (`player.capacity = Number(data.maxSlots)`, same for `other`). Once capacity is per-inventory, the server needs to send each book's own capacity distinctly (e.g. `playerMaxSlots`/`otherMaxSlots`) so a player's personal effects book and a large storage chest opened alongside it can genuinely differ in size.

This also gives the hotbar design question (§10.2) a cleaner answer: a hotbar can be "the first N compartments of the always-visible page" rather than needing a wholly separate UI strip, since scrolling already establishes the idea of "more exists below the visible page."

## 11. Delivery phases

Two tracks. The `INV-W*` track matches `DEPENDENCY_SUPPORT_PLAN.md` §4.5 exactly (shared vocabulary with the weapons plan). The Inventory-Native track is this resource's own, sequenced by leverage (§10.1 → §10.2 → §10.3), and runs in parallel — neither blocks the other.

### `INV-W1` — Contract and schema foundation
- Finalize `instance_mode` (`stack`/`unique`) on item definitions.
- Design and migrate the versioned metadata document; decide whether flat `item_metadata` survives as a compatibility projection.
- Introduce the shared result envelope/error-code catalog (extending, not replacing, the pattern `GrantItem` already started).
- Add the normalized item-instance read model and a version/capability readiness export.
- **Exit gate:** a unique item with versioned metadata can be created, read, and updated without losing its identity.

### `INV-W2` — Transactions and concurrency
- Implement `Inventory.Transaction(context, fn)` with deterministic multi-item row locking and revision-based compare-and-set.
- Route capacity/slot/quantity/metadata/movement changes through one commit path.
- **Exit gate:** simultaneous updates to one item yield one commit and one explicit conflict.

### `INV-W3` — Movement guards and events
- Add the pre-move/destroy guard registry and the structured post-commit event set.
- Route give/ground/container/admin/deletion through the same pipeline `INV-W2` established.
- **Exit gate:** every item movement is observable after commit; an equipped weapon can be synchronously blocked/unequipped before movement.

### `INV-W4` — Capacity and hardening
- Close the last weight-enforcement gap (`AddItem`, §10.1) as part of this, not separately.
- Add metadata size limits, access-mode checks, failure diagnostics, transaction metrics, and concurrency/rollback/restart tests.
- **Exit gate:** the weapon vertical-slice transaction suite passes against this implementation.

### Inventory-Native Phase A — Close the loop (§10.1)
- ~~`MoveItem` weight/capacity bypass~~ — empty-slot case done; occupied-slot swap across inventories still open (needs net-delta capacity math, see §6).
- Unblock robbery (cross-resource ask to `feather-core`, still open).
- ~~`AddItem` weight parity~~, ~~`GiveItem` distance check~~, ~~surfaced rejection reasons~~, ~~debug print cleanup~~ — done.
- Split-stack action — still open.
- **Exit gate:** every currently-built inventory feature is actually reachable and consistent with the patterns the rest of the resource follows.

### Inventory-Native Phase B — README backlog (§10.2)
- ~~Scrollable grid + per-inventory capacity (§10.4)~~ — **done.** This also resolves README's "Add Inventory specific slot counts" item, and unblocks the hotbar design (it can now be the always-visible first page rather than a separate strip).
- ~~Ground LOD~~ — done.
- Hotbar (as the always-visible first page, per §10.4), locale migration, confirmed Pinia migration, shift+drag-all — still open.
- **Exit gate:** README's "Next Major version improvements" list is empty or explicitly re-scoped.

### Inventory-Native Phase C — New ideas (§10.3), prioritized by leverage
- Condition/durability convention (do this before or alongside `INV-W1`'s metadata document work, since weapons wants the same thing — one design, two consumers).
- Perishables, vehicle/mount containers, quick-loot-all, weight meter, search/filter, admin inspection export, sound feedback audit.
- **Exit gate:** each shipped idea has a clear owner decision recorded (built, deferred with reason, or rejected with reason) — this phase is explicitly open-ended, not a fixed checklist to clear.

### Phase D — Public API documentation
- Document every export's real contract once `INV-W1`–`W4` stabilize it.
- **Exit gate:** `feather-website`'s inventory section (`DOCS-W1`) can be written directly from this.

## 12. Workstream checklist

**Weapons-support (`DEPENDENCY_SUPPORT_PLAN.md` §4.6):**
- [ ] Unique item instance cannot stack or split
- [ ] Metadata document and revision update atomically
- [ ] Reload/attachment/purchase/transfer flows can commit atomically through the transaction API
- [ ] Concurrent requests cannot duplicate ammo, attachments, or weapon instances
- [ ] Post-commit events fire exactly once per committed operation
- [ ] All mutation paths enforce live container access
- [ ] Restart leaves no in-memory lock as persistent authority

**Inventory-native:**
- [x] Capacity model unified behind one `EvaluateInventoryAcceptance` (§6, found/fixed 2026-08-23) — fixes the stack-size/quantity-limit conflation in `AddItem` and `GrantItem`, the unit-count-as-slot-count check in `GrantItem`, and the quantity-less weight sum in `InventoryCanHold`/`ById`
- [x] `GrantItem` now respects the per-inventory blacklist (was skipped entirely)
- [x] `AddItem` no longer reports success on a partial grant
- [x] `MoveItem` weight/capacity bypass fixed for empty-destination-slot case (§6, found 2026-08-21)
- [x] `MoveItem` swap-into-occupied-slot-across-inventories closed via `EvaluateSlotMove`'s net-delta math (§6, 2026-08-23) — also closed the previously-unvalidated return leg
- [ ] Robbery system unblocked (cross-resource ask filed with `feather-core`)
- [x] `AddItem` weight check added
- [x] `GiveItem` server-side distance check added
- [x] Split-stack action shipped (§10.1, 2026-08-23) — same-inventory only, server-enforced cap, UI build + lint verified
- [x] Rejection reasons confirmed surfaced in UI
- [x] Debug prints replaced with gated logger
- [x] Scrollable grid + per-inventory capacity shipped (§10.4, 2026-08-23) — static chrome, scrolling compartments, `inventory.max_slots` self-migration, `RegisterInventory` capacity param, per-book client payload, all six server-side capacity call sites routed through one resolver
- [x] Ground LOD shipped
- [ ] Hotbar (as always-visible first page) / locale / Pinia / shift-drag-all (README backlog)
- [ ] Condition/durability convention documented and shared with weapons
- [ ] Perishables, vehicle containers, quick-loot-all, weight meter, search/filter, admin inspection export — each triaged (built/deferred/rejected)
- [ ] Every export documented against its real contract

## 13. Definition of done

- Inventory supports unique item instances, versioned metadata, atomic multi-item mutations, concurrency control, access assertions, movement guards, and post-commit events (weapons track).
- `feather-weapons` can build creation/equip/reload/attachment services entirely on the transaction API and guard registry.
- Every currently-built inventory feature (robbery, weight enforcement, slot-based UI) is fully reachable and consistent, not partially wired.
- README's outstanding TODO and "Next Major version" lists are empty or explicitly re-scoped.
- Each §10.3 idea has a recorded decision, not silence.
- Every export has a documented, accurate result-envelope contract.
- The cross-resource test matrix (`DEPENDENCY_SUPPORT_PLAN.md` §15, inventory column) passes on a clean database and after resource/server restarts.
