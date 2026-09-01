# Feather Inventory

Feather inventory is designed to provide a realistic and immersive inventory system for players. It is based on weight, allowing players to manage their items effectively. Additionally, it includes a player-to-player looting/search access system for lawful and criminal consumers and the ability to register usable items. Moreover, the script comes with an API that enables the registration of custom inventories for various entities.

## Features

### Hotbar

The inventory hotbar provides persistent per-character quick-slot bindings and
uses `Shift+1` through `Shift+6` by default so it does not collide with RedM's
built-in plain-number weapon wheel. Stackable items bind by definition and
continue to work as individual instances are consumed/replenished; unique items
bind to their exact instance.

```lua
Config.Hotbar = {
    Enabled = true,
    Visibility = 'UserDefined', -- Temporary | Always | UserDefined
    DefaultVisibility = 'Temporary',
    DefaultOpacity = 90,        -- 50..100 until the player saves a preference
    TemporaryDuration = 4000,
    Modifier = 'SHIFT',
    Slots = 6,
}
```

`Enabled=false` disables assignment, input, rendering, and server use requests.
`Temporary` and `Always` are forced operator policies. `UserDefined` exposes a
Temporary/Always choice through `feather-settings`; the presentation preference
is stored locally by Inventory and survives resource/game restarts. Existing
bindings/preferences are preserved while the feature or player choice is
disabled.

When Settings is available, visibility uses Feather Menu's compact arrow
selector and opacity uses a 50–100 percent slider. Slot borders and available
item icons remain fully opaque while the parchment and labels follow the preference. Both apply immediately and
persist in Inventory-owned client KVPs.

While the ledger is open, drag a usable item from the player's book directly
onto a hotbar slot to assign or replace it. Right-click a hotbar slot to clear
its binding. Every use re-resolves current ownership on the server; the client
never supplies the item instance to use.

1. **Player inventory**: Provides players with an inventory
2. **Secondary/Custom inventory**: Developers can utilize the API provided by the script to register custom inventories for various entities within the game. This feature allows for expanded gameplay possibilities, such as creating unique loot systems or interactive objects.
3. **Ground inventory**: A global ground inventory for when players drop items
4. **Usable Items**: The inventory system supports registering usable items, such as consumables or items that trigger specific actions when used.
5. **Custom Inventory API**: Developers can easily register custom inventories for different entities within the game, expanding the functionality of the script to cater to specific gameplay scenarios.
6. **Trusted grant API**: Server resources can list item definitions and atomically grant validated catalog items to an inventory.
7. **Item instances & versioned metadata**: Definitions are `stack` or `unique`; each owned row carries a versioned JSON metadata document with compare-and-set.
8. **Transactions**: Multi-item mutations commit atomically or not at all, with real `SELECT ... FOR UPDATE` row locking — concurrent callers queue rather than racing.
9. **Movement guards & post-commit events**: Other resources can veto a move before it happens and observe every mutation after it commits.
10. **Persisted equipment slots**: A generic `character × slot → instance` store that survives a reconnect or a restart, with no idea what a weapon is.
11. **Canonical character UUID support**: Character ownership, access grants, equipment, and transactional issuance preserve Contract 1 UUIDs end to end.

## Character UUID cutover

The clean-slate Character rebuild replaces numeric character IDs with UUIDs. New databases created from `feather-recipe/database/migration.sql` use `CHAR(36)` ownership columns and do not create cross-resource foreign keys to the legacy `characters` table.

All Feather UUID values, including `inventory.uuid`, are stored as `CHAR(36)`. Inventory generates each value explicitly before insertion. Feather does not require MariaDB's newer native `UUID` datatype or UUID expression defaults, preserving compatibility with older MariaDB installations.

To convert only an existing native `inventory.uuid` column without performing
the Character identity cutover, back up the database and run
`feather-inventory/database/inventory_uuid_char36.sql`.

For an existing development database, either rebuild the inventory tables from the updated recipe (recommended) or back up the database and run:

```text
feather-inventory/database/character_uuid_cutover.sql
```

Character identity is UUID-only. Numeric legacy character IDs are rejected at Inventory boundaries and are not part of the release contract.

After applying the schema and performing a full server restart, run in the server console:

```text
InvCharacterUuidSmokeTest [serverId]
```

All six checks must pass before enabling the UUID Character flow.

## Getting Started

Follow these steps to set up the RedM inventory script in your server:

1. **Prerequisites**: Download the latest release from [Releases](https://github.com/FeatherFramework/feather-inventory/releases)
2. **Installation**: Place the script files in your RedM server's resource folder. Ensure the feather-inventory in your [RESOURCE CONFIG FILE]
3. **Dependencies**: Feather Core - Feather core is the only dependency as of now.
4. **Configuration**: Adjust the settings in the configuration file to suit your server's gameplay style and preferences.
5. **Database Setup**: The database should be created for you automatically. If you are having issues please delete the table and restart the script.

---

# API Reference

Hosted documentation: [featherframework.net/api/Inventory](https://featherframework.net/api/Inventory) — note that it may lag behind this file, which is written against the current source.

```lua
-- server
local Inventory = exports['feather-inventory'].initiate()
-- client
local Inventory = exports['feather-inventory'].initiate()
```

The server export exposes:

| Key | What it covers |
|---|---|
| `Inventory` | Containers, capacity, open/close, access control |
| `Items` | Definitions, grants, removal, use, drop, condition |
| `Categories` | Ledger category tabs |
| `Instances` | Item identity, `stack`/`unique` mode, versioned metadata |
| `Transaction` / `MutateItem` / `CreateInstance` | Atomic, row-locked multi-item mutations |
| `DestroyInstances` / `UseItemAction` | Exact audited destruction and declarative atomic use |
| `Guards` | Veto a move or destroy before it happens |
| `Equipment` | Persisted `character × slot → instance` |
| `Diagnostics` | Transaction counters and read-only integrity scans |

Provider functions are also aliased at the **top level**: `GetCapabilities`,
`GetItemForCharacter`, `GetEquippedForCharacter`,
`SetEquippedForCharacter`, and `GetCharacterInventory`.

### Supported server surface index

This is the supported `initiate()` contract. Functions present on the Lua
tables but omitted here—`Internal*`, `RegisterInternalUseGuard`, locked-snapshot
guard helpers, and `Emit*`—are resource-private implementation details.

| Surface | Supported methods |
|---|---|
| Top level | `Transaction`, `MutateItem`, `CreateInstance`, `DestroyInstances`, `UseItemAction`, `GetCapabilities`, `GetItemForCharacter`, `GetEquippedForCharacter`, `SetEquippedForCharacter`, `GetCharacterInventory` |
| `Inventory` | `RegisterForeignKey`, `RegisterInventory`, `GetInventory`, `GetCustomInventory`, `GetCharacterInventory`, `GetInventoryItems`, `InventoryCanHold`, `InventoryCanHoldById`, `EvaluateSlotMove`, `OpenInventory`, `CloseInventory`, `CanAccessInventory`, `IsInventoryAccessibleBySrc`, `GetInventoryOwner`, `GetInventoryOwnerResult`, `GetInventoryOwnerAndVisibility`, `GrantInventoryAccess`, `RevokeInventoryAccess`, `ListInventoryAccess`, `HasInventoryAccessGrant`, `SetInventoryPublic`, `GrantTemporaryAccess`, `RevokeTemporaryAccess`, `HasTemporaryAccess`, `GetContainerLifecycle`, `DeleteContainerIfEmpty`, `RecoverContainerContents` |
| `Items` | `GetDefinitions`, `ItemExists`, `GetItem`, `GetItemCount`, `InventoryHasItems`, `GrantItem`, `AddItem`, `RemoveItemByName`, `RemoveItemById`, `DropItemsOnGround`, `RegisterUsableItem`, `RegisterUsableAction`, `UseItem`, `GetCondition`, `SetCondition`, `AdjustCondition` |
| `Instances` | `GetCapabilities`, `GetInstance`, `GetItemForCharacter`, `FindInstances`, `IsUniqueDefinition`, `SetInstanceMode`, `SetDefinitionArchived`, `GetDefinitionMigrationPreflight`, `MigrateDefinitionInstances`, `ReadMetadata`, `WriteMetadata`, `MergeMetadata` |
| `Equipment` | `GetEquippedForCharacter`, `SetEquippedForCharacter`, `ClearEquippedInstance`, `IsInstanceEquipped` |
| `Guards` | `RegisterMoveGuard`, `UnregisterMoveGuard`, `RegisterDestroyGuard`, `UnregisterDestroyGuard`, `CanMoveInstance`, `CanDestroyInstance` |
| `Diagnostics` | `GetTransactionMetrics`, `RunIntegrityDiagnostics` |
| `Categories` | `GetCategories` |

Direct Cfx exports are `initiate`, `GetCharacterInventory`,
`RemoveCharacterInventoryInstance`, and `GrantCharacterItem`. The latter three
are trusted server-only UUID Character adapters documented below.

The client export exposes only `Action`.

## Result shapes

**Every export returns a result envelope.** There is one convention, not two.

```lua
{ ok = true,  value = <result>, correlationId = <id?> }
{ ok = false, error = { code = 'stable_code', message = '...', details = {} }, correlationId = <id?> }
```

The API contract version is `2`. Read it from `GetCapabilities().value.contractVersion` and refuse to start against anything lower — a key-existence check cannot detect a changed return shape.

`code` is stable and machine-readable; `message` is developer-facing English. Player-facing text is resolved separately from `translations/` via the matching `err_<code>` key.

> Test envelopes with `Result.IsOk(result)` or `result.ok == true`, never `if result then` — a failure envelope is itself a truthy table, so a bare truthiness test treats every error as success.

Stable codes: `invalid_input`, `not_found`, `denied`, `conflict`, `unsupported`, `limit_exceeded`, `dependency_missing`, `internal`.

---

## `Inventory` — containers, capacity, access

### Registration

Two calls, in this order. `RegisterForeignKey` runs once per resource at startup and adds a `<tablename>_id` column to `inventory`; `RegisterInventory` runs once per entity and hands you back the UUID to store on your own row.

```lua
local Inventory = exports['feather-inventory'].initiate()

AddEventHandler('onResourceStart', function(resource)
  if resource ~= GetCurrentResourceName() then return end
  -- `wagons` is your table; `id` is its primary key.
  Inventory.Inventory.RegisterForeignKey('wagons', 'BIGINT UNSIGNED', 'id')
end)

-- Later, when a wagon is spawned or first opened:
local registered = Inventory.Inventory.RegisterInventory(
  'wagons',            -- tableName, must match the foreign key you registered
  wagon.id,            -- id, the row in your table
  'Wagon Bed',         -- displayName, shown on the ledger page
  false,               -- ignoreItemLimits
  400.0,               -- maxWeight in pounds (nil = Config.maxWeight, 0 = unlimited)
  { 'consumable_moonshine' }, -- restrictedItems, blacklisted by name
  wagon.ownerCharacterId,     -- ownerCharacterId, may grant/revoke access
  false,               -- isPublic
  60                   -- maxSlots (nil = Config.maxItemSlots)
)

if not registered.ok then
  print(registered.error.code, registered.error.message)
  return
end

MySQL.update.await('UPDATE wagons SET inventory_uuid = ? WHERE id = ?',
  { registered.value.uuid, wagon.id })
```

`RegisterInventory` returns `Ok({ uuid, id })` — the **UUID** is what you store and pass to most `Items` functions; the numeric **id** is what the `Instances`, `Transaction` and access functions take. Positional multi-returns became named tables in contract 2; `GetInventory` and `GetCustomInventory` used to return their fields in different orders.

Notes that catch people out:

- `maxWeight` — `nil` uses `Config.maxWeight`; **`0` means no weight limit** (ground piles register this way, since a heap on the floor has nothing doing the carrying). Slot and per-item quantity limits still apply at `0`.
- `maxSlots` — `nil` uses `Config.maxItemSlots`. Capacity is per-inventory and the ledger grid scrolls, so it is not bounded by what fits on one visible page.
- `ownerCharacterId` / `isPublic` / `maxSlots` / `maxWeight` are written **only when explicitly passed**. Omitting one on a re-register never resets a stored setting — so calling `RegisterInventory('wagons', id)` on every spawn is safe.

Before deleting an entity that owns a container, its resource can inspect and
close the Inventory side safely:

```lua
local state = Inventory.Inventory.GetContainerLifecycle(inventoryId)
if state.ok and state.value.itemCount == 0 then
  local deleted = Inventory.Inventory.DeleteContainerIfEmpty(
    inventoryId, 'wagons', 'wagon permanently deleted')
end
```

Deletion locks the container and its item rows, rechecks the owner domain, and
fails with `conflict` if anything remains. Character and Ground containers are
protected from this consumer API. Deleting the owning wagon/property row before
this succeeds is a consumer bug: its foreign-key cascade is cleanup machinery,
not permission to destroy player property.

To retain property while deleting its owner, recover and delete atomically:

```lua
local recovered = Inventory.Inventory.RecoverContainerContents(
  wagonInventoryId, characterInventoryId, 'wagons', 'wagon permanently deleted')
```

Every instance is locked, guard-checked, capacity-checked, moved to the named
recovery inventory, and announced through normal post-commit movement facts.
The source container is deleted in that same transaction only if no unlisted or
concurrently-added item remains. The consumer may delete its owning entity only
after this call succeeds.
- `tableName` and `primaryKeyName` must be valid SQL identifiers; they are concatenated into DDL and are rejected otherwise.

### Reads

```lua
-- By UUID or by raw id -- GetInventoryById handles both.
local found = Inventory.Inventory.GetInventory(uuid)
if found.ok then
  print(found.value.id, found.value.maxWeight, found.value.ignoreItemLimit, found.value.name)
end

-- Custom inventory, resolved through your own foreign key column.
local wagonInv = Inventory.Inventory.GetCustomInventory('wagons', wagon.id)
-- wagonInv.value = { id, uuid, maxWeight, ignoreItemLimit }

-- Everything in a container, as rows the ledger renders.
local contents = Inventory.Inventory.GetInventoryItems(id)
for _, item in ipairs(contents.value) do
  print(item.name, item.slot_index, item.metadata and item.metadata.condition)
end
```

Consumer resources can resolve a UUID Character's own container without
querying Inventory's tables directly:

```lua
local characterInventory = exports['feather-inventory']:GetCharacterInventory(characterId)
if characterInventory.ok then
  print(characterInventory.value.id, characterInventory.value.maxWeight)
end
```

Trusted server resources that need to remove a selected instance can use the
locked, ownership-scoped path below. It rejects stale/moved instance IDs and
runs every registered destroy guard before committing:

```lua
local removed = exports['feather-inventory']:RemoveCharacterInventoryInstance(
  characterId, instanceId, 'admin_remove')
```

Stackable catalog items can be granted atomically to an online or offline
UUID Character. Unique definitions are rejected and must use their owner:

```lua
local granted = exports['feather-inventory']:GrantCharacterItem(
  characterId, 'revolver_standard', 24, 'admin_ammo_grant')
```

### Capacity

```lua
local items = { { item = 'consumable_apple', quantity = 5 }, { item = 'matches', quantity = 10 } }

-- Player source or inventory UUID:
local check = Inventory.Inventory.InventoryCanHold(items, source)
if not check.ok then
  return  -- the evaluation itself failed
end
if check.value.accepted == false then
  print(check.value.code, check.value.message)  --> 'weight_limit', 'Max Weight Exceeded.'
  return
end

-- Raw inventory.id:
local check = Inventory.Inventory.InventoryCanHoldById(items, inventoryId)

-- Already resolved the inventory and its limits yourself:
local check = Inventory.Inventory.EvaluateInventoryAcceptance(
  inventoryId, maxWeight, ignoreItemLimit, items)

-- Would this drag-and-drop fit, in both directions?
local move = Inventory.Inventory.EvaluateSlotMove(fromInventoryId, 3, toInventoryId, 7)
```

All four return `Ok({ accepted = boolean, code = string?, message = string })`.

> **A refusal is a success.** "This inventory cannot hold that" is a question that was answered, so it comes back as `ok = true` with `accepted = false`. `ok = false` means the evaluation itself failed — a missing inventory, a database error. Keeping them apart is the point: a dead connection and a full backpack must not take the same branch.

`EvaluateInventoryAcceptance` is the single definition of "can this inventory accept N of these" — quantity cap, slot capacity accounting for stacking, weight, and blacklist. The two `InventoryCanHold*` functions are thin wrappers over it that differ only in how they resolve the inventory.

- `InventoryCanHold` takes a **player source or inventory UUID**; `InventoryCanHoldById` takes a **raw `inventory.id`**. Passing a raw id to the former is misread as a source — use the `ById` variant for ids.
- `EvaluateSlotMove` uses net-delta math (`current − leaving + arriving`) on **both** inventories, so a swap at the weight limit trading equal weights is correctly allowed, and a swap whose *return leg* would overload the source is correctly rejected.

### Open / close

```lua
-- Open the player's own book:
Inventory.Inventory.OpenInventory(source)

-- Open it paired with a container, by UUID:
Inventory.Inventory.OpenInventory(source, wagonUuid, 'storage')

Inventory.Inventory.CloseInventory(source)
```

`OpenInventory`/`CloseInventory` are the client-facing pair — they trigger the ledger UI. `InternalOpenInventory(src, otherInventoryId)` returns the item payload directly without touching the UI, and `InternalCloseInventory(src)` releases the open-inventory lock (called for you on disconnect).

### Access control

```lua
local modes = Inventory.Inventory.AccessModes  -- READ | INSERT | REMOVE | MANAGE

local decision = Inventory.Inventory.CanAccessInventory(source, inventoryId, modes.REMOVE, {
  reason = 'weapons_reload',
  correlationId = correlationId,
})
if decision.ok ~= true then
  print(decision.error.code, decision.error.message)  --> 'denied', 'You are too far away.'
  return
end
```

Sharing a container with another character:

```lua
-- `source` must own the inventory (or be an admin) for these to succeed.
Inventory.Inventory.GrantInventoryAccess(source, inventoryId, partnerCharacterId)
Inventory.Inventory.RevokeInventoryAccess(source, inventoryId, partnerCharacterId)
Inventory.Inventory.SetInventoryPublic(source, inventoryId, true)

for _, grant in ipairs(Inventory.Inventory.ListInventoryAccess(source, inventoryId) or {}) do
  print(grant.character_id)
end

-- Direct queries, no `src` involved:
local ownerCharacterId          = Inventory.Inventory.GetInventoryOwner(inventoryId)
local ownerCharacterId, isPublic = Inventory.Inventory.GetInventoryOwnerAndVisibility(inventoryId)
local hasGrant = Inventory.Inventory.HasInventoryAccessGrant(characterId, inventoryId)
```

Short-lived access, for a world interaction that should not outlive the moment:

```lua
Inventory.Inventory.GrantTemporaryAccess(source, inventoryId, 30)  -- seconds
Inventory.Inventory.HasTemporaryAccess(source, inventoryId)        --> boolean
Inventory.Inventory.RevokeTemporaryAccess(source, inventoryId)
```

`IsInventoryAccessibleBySrc(src, inventoryId)` is the blunt boolean underneath all of it — prefer `CanAccessInventory`, which asks the real question.

Only `MANAGE` currently resolves differently: it is owner/admin only and is never granted by proximity or public visibility. A ground pile is readable and lootable by anyone near it, and manageable by nobody — modelling that honestly beats inventing four permission bits that all resolve identically.

Access is re-checked on every call rather than cached, so a mutation arriving late cannot ride an authorization that was true a minute ago.

---

## `Items` — grants, removal, use, condition

Throughout this table, `inventoryId` follows the framework's dual convention: **numeric = player source**, **string = inventory UUID**.

### Definitions and counts

```lua
local defs = Inventory.Items.GetDefinitions()
for _, def in ipairs(defs.value) do
  -- Skip unique definitions in a generic grant browser -- they carry
  -- per-instance state and GrantItem refuses them (unique_requires_issuer).
  if def.instance_mode ~= 'unique' then
    print(def.name, def.display_name, def.weight, def.max_stack_size, def.category)
  end
end

Inventory.Items.ItemExists('consumable_apple')          --> Ok(boolean)
Inventory.Items.GetItem(instanceId)                     --> Ok(row) | Err(not_found)
Inventory.Items.GetItemCount('consumable_apple', source)--> Ok(number)

Inventory.Items.InventoryHasItems({
  { name = 'wood', quantity = 4 },
  { name = 'nails', quantity = 12 },
}, source)                                              --> Ok(boolean)
```

> **Predicates return `Ok(boolean)`.** `Result.IsOk()` is true for a successful `false`, so read `.value` — and fail closed when `ok` is false. A failure envelope is itself truthy, so testing the envelope rather than its value grants access on a database error.

> `InventoryHasItems` takes `name`, while the capacity functions take `item`. They are different shapes; worth double-checking when you copy a table between them.

### Granting

`GrantItem` is the **trusted** path — admin tools, rewards, scripted payouts. It validates quantity, catalog membership, slot capacity, weight, per-item quantity cap and the blacklist atomically, and returns stable codes.

> **`GrantItem` refuses `unique` definitions** with `unique_requires_issuer`. It creates rows through a batched `INSERT` with no metadata, so granting a weapon this way would produce an instance with an empty document — present and equippable, with nothing for its owning resource to read. Unique items are issued by whichever resource models them, which creates the instance and its complete document in one transaction. Filter them out of any generic grant UI using `instance_mode` from `GetDefinitions`.

```lua
local result = Inventory.Items.GrantItem('consumable_apple', 10, source)
if not result.ok then
  -- 'invalid_item' | 'invalid_quantity' | 'invalid_inventory' | 'inventory_full'
  -- 'weight_limit' | 'item_restricted' | 'database_error' | 'unique_requires_issuer'
  print(result.error.code, result.error.message)
  return
end

print(result.value.displayName, result.value.quantity)
for _, instanceId in ipairs(result.value.instanceIds) do
  -- Real inventory_items ids, so you can immediately attach metadata.
  Inventory.Instances.MergeMetadata(instanceId, { source = 'daily_reward' })
end
```

`AddItem` is the older compatibility path. It accepts initial metadata and now
delegates to the same row-locked transaction used by newer grants, so capacity,
placement, creation, and post-commit facts are atomic. Success reports
`granted`/`requested` plus the created instance ids; failure grants nothing.

```lua
local result = Inventory.Items.AddItem('consumable_apple', 10, { picked = true }, source)

if not result.ok then
  print(result.error.code, result.error.message)
end
```

Definitions may be retired without deleting player property:

```lua
local archived = Inventory.Instances.SetDefinitionArchived(definitionId, true,
  'Replaced by the revised medical item catalog')

local migrated = Inventory.Instances.MigrateDefinitionInstances(
  oldDefinitionId, replacementDefinitionId, 'Catalog replacement')
```

Use `GetDefinitionMigrationPreflight(oldDefinitionId, replacementDefinitionId)`
for advisory counts and compatibility before presenting confirmation; the
committing call repeats authoritative validation under locks.

Archived definitions disappear from the grant catalog and every transactional
creation path rejects them. Existing instances remain readable, movable,
usable, and removable. Passing `false` restores the definition. Changing a
definition between `stack` and `unique` is rejected while any owned instances
exist; that change requires an explicit migration.

`MigrateDefinitionInstances` preserves every owned instance id, inventory,
slot, and metadata document while atomically reassigning it and archiving the
source. It rejects incompatible weight, quantity-limit, stack-size, or
instance-mode semantics and revalidates affected stacks before commit.

Stackable units share a compartment only when their decoded metadata documents
are semantically equal. JSON key order does not matter, but different quality,
condition, stolen state, batch, label, or spoilage data prevents joining. The
unit receives a separate compartment instead; Inventory never chooses one
unit's metadata as representative for a heterogeneous stack.

### Removing and dropping

```lua
-- Any n units of a definition, no particular order.
local removed = Inventory.Items.RemoveItemByName('wood', 4, source)
if removed.ok then
  print(removed.value.removed, table.concat(removed.value.instanceIds, ','))
end

-- One specific instance.
local gone = Inventory.Items.RemoveItemById(instanceId)

-- Onto the ground, joining a nearby pile if one is within Config.Dropped.GroupingRadius.
local dropped = Inventory.Items.DropItemsOnGround(inventoryId, { { id = instanceId } }, x, y, z)
```

Both removal helpers run inside the row-locked transaction pipeline, consult
the **destroy guards**, and refuse with `code = 'denied'` if any guard vetoes.
`RemoveItemByName` is all-or-nothing: a partial removal because one unit was
vetoed would be worse than refusing the request. Ground dropping is movement,
so it consults move guards and preserves the item instances.

### Usable items

```lua
-- Register once at startup:
Inventory.Items.RegisterUsableItem('consumable_apple', function(item, src, refresh)
  Feather.Character.AdjustHunger(src, 10)
  local removed = Inventory.Items.RemoveItemById(item.id)
  if not removed.ok then return removed end
  refresh()  -- repaints the ledger if that player already has it open
  return { ok = true }
end)

-- Called for you when a player uses the item from the ledger; also callable directly.
Inventory.Items.UseItem(instanceId, source)
```

For inventory-owned effects, prefer the atomic data-only contract:

```lua
Inventory.Items.RegisterUsableAction('consumable_apple', {
  consume = true,
}, function(committed, item, src, refresh)
  TriggerEvent('my-health:apple-eaten', src)
  refresh()
end)
```

An action uses either `consume = true` or `metadata = { ... }` (whole-document
replacement), never both. Ownership, live access, revision, guards, mutation,
and audit events share one transaction. The optional callback is explicitly
post-commit; if it fails, the error reports `mutationCommitted = true` because
arbitrary gameplay effects cannot roll back a committed database mutation.

Only one usable callback may run for a given instance at a time. While it is
running, Inventory's internal guards prevent that instance from being moved or
destroyed by another operation. Callback errors become an `internal` failure, and a callback may
return a failed Result to propagate a domain rejection. Legacy callbacks that
return nothing retain their successful behavior. Consumers that consume or
mutate the item should use Inventory's transactional APIs inside the callback;
arbitrary cross-resource gameplay callbacks are not held inside a database
transaction.

The callback receives the joined item row, the player source, and a `refresh`
callback. The owning resource may replace its own registration; another
resource receives a conflict and cannot take it over. `UseItem` re-derives
ownership from the item's own `inventory_id` — a client cannot use an item it
does not hold.

### Metadata

Per-instance metadata lives on `Instances` — see [that section](#instances--item-identity-and-versioned-metadata). There is no `Items.SetMetadata`; it was a passthrough that discarded the envelope and the correlation id.

```lua
Inventory.Instances.MergeMetadata(instanceId, { ammo = 5, chambered = true })
```

### Condition / durability

A generic per-instance `0..Config.Condition.Max` wear value stored in the metadata document. This resource owns the **convention** — key, range, clamping, display — and none of the **policy**: when an item wears and by how much belongs to whichever resource models that behaviour.

```lua
local condition = Inventory.Items.GetCondition(instanceId)  --> Ok(number|nil)

-- Absolute, clamped into range:
Inventory.Items.SetCondition(instanceId, 80)

-- Relative -- the common case. An instance with no condition recorded is treated as full,
-- so you can wear an item that was never explicitly initialised.
local worn = Inventory.Items.AdjustCondition(instanceId, -5)
if not worn.ok then
  print(worn.error.code)  --> 'condition_not_supported' on a stackable definition
else
  print(worn.value.condition, worn.value.revision)
end
```

> `SetCondition` **refuses stackable definitions**. New joins are metadata-safe,
> but changing one row already inside a multi-unit compartment would make that
> existing stack heterogeneous unless the mutation also split it. Set
> `instance_mode = 'unique'` on definitions carrying independently mutable state.

---

## `Instances` — item identity and versioned metadata

`instanceId` is the `inventory_items` row id. It is **preserved across movement** — rows are updated, never deleted and recreated — so a transferred item keeps its identity, its metadata and its revision.

### Reading

```lua
local result = Inventory.Instances.GetInstance(instanceId)
if result.ok then
  local it = result.value
  print(it.id, it.inventoryId, it.slot)
  print(it.revision)
  print(it.metadata.ammo)
  print(it.definition.name, it.definition.weight, it.definition.instanceMode)
end

-- Ownership-asserting read: NOT_FOUND if that character does not actually hold it.
local mine = Inventory.Instances.GetItemForCharacter(characterId, instanceId)

-- Every instance of a definition inside ONE inventory. Scoped deliberately --
-- a global search would leak inventories the caller cannot access.
local rounds = Inventory.Instances.FindInstances(inventoryId, 'ammo_revolver')
if rounds.ok then print(#rounds.value) end
```

**One revision, and it covers movement.** `revision` is `row_revision`, and it moves for *any* change to the row — a metadata write, a move to another inventory, a slot change. That is what compare-and-set compares: a caller that read ammunition and had it moved to someone else's inventory before writing must conflict rather than consume it from its new owner. A separate document-only counter used to sit beside it; it was removed, because nothing asked the narrower question and two counters made every new compare-and-set a guess about which one to pass.

### Stack vs unique

```lua
Inventory.Instances.IsUniqueDefinition(definitionId)          --> boolean
Inventory.Instances.SetInstanceMode(definitionId, 'unique')   --> Result
```

A `unique` definition never joins an existing compartment. Transactional
creation and movement enforce that rule alongside metadata compatibility.
Changing mode is rejected while owned instances exist, because silently
reinterpreting existing stacks would change their identity semantics.

### Metadata document

```lua
local current = Inventory.Instances.ReadMetadata(instanceId)
-- current.value = { document = { ... }, revision = 4 }
-- An instance with no document reads as an empty table, never nil.

-- Compare-and-set: only lands if the revision still matches.
local written = Inventory.Instances.WriteMetadata(instanceId, { ammo = 5 }, current.value.revision)
if not written.ok and written.error.code == 'conflict' then
  print(written.error.details.expected, written.error.details.actual)
end

-- Read-modify-write of a subset of keys, retrying once on conflict. nil removes a key.
Inventory.Instances.MergeMetadata(instanceId, { chambered = true, jammed = nil }, correlationId)
```

- `WriteMetadata` **replaces** the whole document; `MergeMetadata` patches it. Omitting `expectedRevision` on `WriteMetadata` is deliberate last-writer-wins for callers that genuinely do not care.
- Metadata writes are transactional. A row sharing a compartment with other units may only be written to the same semantic document as its peers; independently mutable state belongs on a `unique` definition.
- Documents are capped at **4096 bytes** (`limit_exceeded`, with `details.size` and `details.limit`).
- A row whose JSON will not parse warns and reads as an empty document rather than stranding the instance.

### Capabilities

```lua
local caps = Inventory.GetCapabilities()   -- also Inventory.Instances.GetCapabilities()
if not caps.ok or (tonumber(caps.value.contractVersion) or 0) < 2 then
  error('feather-inventory contract 2 or newer is required')
end
if not caps.value.features.rowLocking then
  error('feather-inventory is too old: this resource needs row locking')
end
```

Check `contractVersion` **before** registering anything against the API. It is a plain integer, deliberately separate from the human-readable semver `version` — a consumer compares it numerically, and `tonumber('2.0.0')` is `nil`. A key-existence check cannot detect a changed return shape, so this is the gate that turns a version mismatch into a clear startup failure rather than a silently misread result. Current flags include `instanceMode`, `metadataDocument`, `instanceRevision`, `instanceReadModel`, `resultEnvelope`, `transactions`, `movementGuards`, `postCommitEvents`, `accessModes`, `metadataSizeLimit`, `transactionMetrics`, `rowLocking`, `equippedState`, `atomicCreation`, `definitionMigration`, `auditedDestruction`, `atomicUseActions`, and `integrityDiagnostics`.

---

## `Transaction` — atomic, row-locked multi-item mutations

Everything inside the body either commits together or not at all. Rows read with `GetItemForUpdate` are **locked** for the rest of the transaction, so a concurrent caller queues rather than racing you.

```lua
local result = Inventory.Transaction({
  actorSource = source,
  actorCharacterId = characterId,
  reason = 'weapon_reload',
  correlationId = correlationId,
  idempotencyKey = ('reload:%s:%s'):format(instanceId, requestId),
  resource = GetCurrentResourceName(),
}, function(tx)
  local locked = tx:GetItemForUpdate(weaponInstanceId)
  if not locked.ok then return locked end
  local weapon = locked.value

  local needed = 6 - (weapon.metadata.ammo or 0)
  if needed < 1 then
    return Result.Err(Result.Codes.INVALID_INPUT, 'Already loaded.')
  end

  local consumed = tx:RemoveQuantity(weapon.inventoryId, ammoDefinitionId, needed)
  if not consumed.ok then return consumed end

  local written = tx:SetMetadata(weapon.id, { ammo = 6 }, weapon.revision)
  if not written.ok then return written end

  return { loaded = needed, revision = written.value.revision }
end)

if result.ok then
  print(result.value.loaded)
else
  print(result.error.code, result.error.message)
end
```

Returning a **failure envelope** from the body is a deliberate rejection: everything rolls back and your reason is preserved. Raising an error rolls back too and comes back as `internal`.

`context` improves auditability and **never grants authority**. When it names an `actorSource`, every mutating operation on the handle asserts that actor's *live* access to the inventory it touches — per operation, not once per transaction, because a transaction can touch several inventories and access to one is not access to another. A context with no `actorSource` is a trusted server-side operation and is not gated.

### Handle methods

| Method | Effect |
|---|---|
| `tx:GetItemForUpdate(instanceId)` | Read **and lock** one instance. `Result<instance>` in the same shape `GetInstance` returns. |
| `tx:GetQuantity(inventoryId, definitionId)` | Count, taken inside the transaction so it cannot drift before the decision based on it commits. |
| `tx:AddQuantity(inventoryId, definitionId, quantity, metadata?)` | Create instances, placed by the usual join-or-claim rule. Metadata goes in with the `INSERT`. `Result<{instanceId,...}>` |
| `tx:CreateInstance(inventoryId, definitionId, metadata)` | One **unique** instance with its complete initial document. Refuses a `stack` definition (`unsupported`). `Result<{instanceId, revision}>` |
| `tx:RemoveQuantity(inventoryId, definitionId, quantity)` | Consume n units; rows are locked before deletion so a concurrent transaction cannot consume the same ammunition. |
| `tx:RemoveInstances(inventoryId, definitionId, { ids })` | Remove **exactly** the instances you named, so you commit the ones your preflight actually calculated against. A row that moved or vanished yields `conflict`. |
| `tx:SetMetadata(instanceId, document, expectedRevision?)` | Replace the document. `expectedRevision` is compared against `row_revision`. |
| `tx:MoveInstance(instanceId, toInventoryId, toSlot)` | Relocate, preserving identity and metadata. Asks the move guards first. |
| `tx:AssertAccess(src, inventoryId, action)` | Re-check access *inside* the transaction — an inventory having been opened earlier is not authority at commit time. |

### Crossing a resource boundary

A Lua handle carrying methods cannot cross a Cfx export; only data can. These two take a specification and run the locked mutation entirely inside `feather-inventory`:

```lua
-- Consume 6 rounds and update the weapon's document, atomically:
local result = Inventory.MutateItem({ reason = 'reload', actorSource = source }, {
  itemInstanceId = weaponInstanceId,
  expectedRevision = knownRevision,       -- optional; conflicts if the row moved on
  removals = {
    { definitionId = ammoDefinitionId, quantity = 6 },
    -- or name the exact rows your preflight used:
    -- { definitionId = ammoDefinitionId, instanceIds = { 41, 42, 43 } },
  },
  additions = { { definitionId = casingDefinitionId, quantity = 6 } },
  metadata = { ammo = 6 },
})
--> Result< { itemInstanceId, inventoryId, revision } >

-- Create one unique instance in a character's own inventory:
local created = Inventory.CreateInstance({ reason = 'weapon_purchase' }, {
  characterId = characterId,
  definitionId = revolverDefinitionId,
  metadata = { serial = 'CM-4471', ammo = 0 },
})
--> Result< { instanceId, revision, inventoryId, characterId } >
```

Explicit destruction names exact property and its expected owner domain:

```lua
Inventory.DestroyInstances({
  reason = 'approved evidence disposal',
  resource = GetCurrentResourceName(),
}, {
  inventoryId = evidenceInventoryId,
  expectedLocation = 'evidence',
  instanceIds = { instanceA, instanceB },
})
```

Moved/missing rows or a mismatched domain abort the whole operation. Destroy
guards evaluate locked snapshots and successful deletion emits one committed
fact per instance.

### Idempotency

An `idempotencyKey` in the context makes a repeated call return the first call's cached result instead of executing again.

> **The cache is in-memory and does not survive a restart.** A request retried across a resource or server restart finds no record and **will execute again**. That is fine for a reload or a repair. For anything **economic** — a purchase, a payout, anything a player is charged for — keep your own persisted idempotency record keyed on your own domain. The cache is bounded at 500 entries / 60s, because an unbounded cache keyed by caller-supplied strings is a memory-exhaustion vector.

### Diagnostics

```lua
local m = Inventory.Diagnostics.GetTransactionMetrics()
--> { started, committed, rolledBack, conflicts, bodyErrors, idempotentHits }

local scan = Inventory.Diagnostics.RunIntegrityDiagnostics({ sampleLimit = 50 })
-- scan.value = {
--   dryRun = true,
--   ok = true, -- no error/critical findings; informational findings may exist
--   summary = { totalFindings, byCode, bySeverity },
--   findings = { { code, severity, details }, ... },
--   truncatedByCode = {},
-- }
```

Returned as a copy, so a caller cannot reset the counters by mutating what it was handed. With real row locking, contending callers queue rather than retry — so `conflicts` is a genuine signal (a cross-request compare-and-set losing) rather than expected background noise, and `rolledBack` is the number to watch.

`/InvTxSmokeTest` (`Config.DevMode`, run in game by an ACE-authorized player
with a loaded Character) exercises the whole path: create + metadata + locked
read, rollback, stale revision, a row deleted mid-flight, a row moved
mid-flight, acceptance gates, unique issuance, and a guard veto.

`InvLifecycleSmokeTest` (F8 console, no leading slash; use
`/InvLifecycleSmokeTest` in chat) uses three fixed disposable definitions to exercise
definition-migration preflight, incompatible rollback, compatible identity and
metadata preservation, revision bumps, source archival, exact destruction,
wrong-domain and stale-set rollback, and post-commit lifecycle facts. It has
the same DevMode, ACE, connected-player, and loaded-Character requirements.
Fixture setup and inspection use SQL; all owned-item mutations use the supported
Inventory transaction contracts. An interrupted run is cleaned up safely by
its exact `inv_smoke_migrate_*` definition names on the next invocation.

`InvConcurrencySmokeTest` (F8; slash-prefixed in chat) coordinates simultaneous
archive/grant and equipment/move requests. It accepts either valid serial
ordering while rejecting retired-item creation and any equipment row whose item
has moved out of the owning Character inventory. Its fixtures use the exact
`inv_smoke_archive_race` definition and a reserved disposable inventory UUID.

The complete release procedure—including exact in-game actions, two-player
ground/entity tests, required fixture setup, every expected smoke-test line,
API harness checks, restart testing, and sign-off—is maintained in
`docs/FEATHER-INVENTORY-TEST-CHECKLIST.md` in the framework workspace.

`RunIntegrityDiagnostics` performs SELECTs only. It reports orphaned ownership
references and grants, missing/archived definitions, malformed metadata,
invalid or excessive slots, mixed/oversized/metadata-incompatible stacks,
stacked unique items, dangling or wrongly-owned equipment, overweight
inventories, and definition quantity violations. Samples are capped per code
from 1–500 while summary counts always include every finding. In DevMode,
`/InvIntegrityCheck [sampleLimit]` prints the same report to the server console.
There is deliberately no repair flag.

---

## `Guards` — vetoing movement, observing mutations

```lua
local Inventory = exports['feather-inventory'].initiate()

Inventory.Guards.RegisterMoveGuard('feather-weapons:equipped', function(instance, context)
  if EquippedInstances[instance.id] then
    return false, 'Holster that before putting it away.'
  end
  return true
end)

Inventory.Guards.RegisterDestroyGuard('feather-weapons:equipped', function(instance, context)
  if EquippedInstances[instance.id] then
    ForceUnequip(instance.id)   -- or return false to refuse outright
  end
  return true
end)

Inventory.Guards.UnregisterMoveGuard('feather-weapons:equipped')
Inventory.Guards.UnregisterDestroyGuard('feather-weapons:equipped')
```

The guard receives the **normalized instance** (same shape as `GetInstance().value`) and the mutation context.

**Guard contract:**

- Guards are **synchronous**. Do not yield — no `Wait`, no `CallAsync`, no MySQL await. There is no way to enforce that in Lua, so it is stated rather than checked: a yielding guard stalls every mutation behind it.
- Return `true` to allow, or `false, reason` to veto.
- **A guard that errors is treated as a veto, not an allow.** A broken guard must not silently become permission.
- Guards hold no state, so a crashed consumer cannot wedge the inventory — there is nothing to release.
- Re-registering the same `name` replaces it, so a resource restart cannot accumulate duplicate guards.

Guards run at the chokepoints every route funnels through — bulk transfer and
give and ground drop and take-all (`MoveInventoryItems`), drag and swap
(`MoveSlotItems`), grants (`CreateInventoryItem`), and the legacy
`RemoveItemByName`/`RemoveItemById`. The two legacy removal helpers now delegate
to the transaction pipeline, so their veto aborts before any delete and their
destruction facts emit only after commit.

You can also ask the question directly, which is useful for greying out an action before the player attempts it:

```lua
local allowed, reason = Inventory.Guards.CanMoveInstance(instanceId, { reason = 'ui_preview' })
local allowed, reason = Inventory.Guards.CanDestroyInstance(instanceId, { reason = 'ui_preview' })
```

The `Emit*` functions on `Guards` are internal — this resource calls them after committing. Consumers listen for the events below rather than emitting them.

### Events

All are **internal** `TriggerEvent` and deliberately *not* network-registered — a networked mutation event would be spoofable by any client. Each payload is a single table.

```lua
AddEventHandler('Feather:Inventory:ItemMoved', function(payload)
  print(payload.instanceId, payload.fromInventoryId, payload.toInventoryId,
        payload.definitionId, payload.revision, payload.correlationId)
end)
```

| Event | Payload keys |
|---|---|
| `Feather:Inventory:ItemCreated` | Common audit keys plus `instanceId, definitionId, inventoryId, destination` |
| `Feather:Inventory:ItemMoved` | Common audit keys plus `instanceId, definitionId, revision, fromInventoryId, toInventoryId, origin, destination` |
| `Feather:Inventory:ItemMetadataChanged` | Common audit keys plus `instanceId, definitionId, inventoryId, revision, origin, destination` |
| `Feather:Inventory:ItemDestroyed` | Common audit keys plus `instanceId, definitionId, inventoryId, origin` |
| `Feather:Inventory:DefinitionMigrated` | Common audit keys plus `sourceDefinitionId, targetDefinitionId` |
| `Feather:Inventory:TransactionCommitted` | Common audit keys plus `summary = { created, moved, destroyed }` |

Common audit keys are `operation, outcome, quantity, actorSource,
actorCharacterId, resource, correlationId, reason, occurredAt`. Events are
emitted only **after** commit, so `outcome` is always `committed`; rejected
attempt storage belongs to an external audit consumer at the API boundary.

These five are the only mutation signals. The old `feather-inventory:ItemAdded` / `feather-inventory:ItemRemoved` pair was removed — every one of its fire sites already sat beside a structured emit carrying strictly more (correlation id, actor, definition id, revision), and its own first argument had meant a *definition* id on one path and an *instance* id on another. Listen for the events above instead.

---

## `Equipment` — persisted equipment slots

Generic `character × slot → instance` storage. `slot` is an arbitrary string **you** choose — `'primary'`, `'sidearm'`, `'holster'`, `'hat'`. Inventory stores and constrains it; you decide what the names mean, so a clothing resource can use the same table without inventory learning about clothing.

This exists because equipped state cannot live only in a consumer's memory: it has to survive a reconnect and a resource or server restart.

```lua
-- Equip. Rejects an instance the character does not actually hold --
-- ownership is re-derived from the item's own row, not taken on your word.
local set = Inventory.SetEquippedForCharacter(characterId, 'sidearm', instanceId)
if not set.ok then print(set.error.code) end  --> 'denied' if they don't hold it

-- Unequip that slot:
Inventory.SetEquippedForCharacter(characterId, 'sidearm', nil)

-- Read one slot, or every slot:
local one = Inventory.GetEquippedForCharacter(characterId, 'sidearm')  --> Result<instanceId|nil>
local all = Inventory.GetEquippedForCharacter(characterId)             --> Result<{ [slot] = instanceId }>

-- Unequip an instance wherever it happens to be slotted -- what a move guard
-- calls when it decides to force an unequip rather than veto:
Inventory.Equipment.ClearEquippedInstance(instanceId)

-- Cheap enough for a guard to call on every move:
local equipped = Inventory.Equipment.IsInstanceEquipped(instanceId)
if equipped.ok and equipped.value then print('equipped') end
```

An instance can only occupy one slot at a time (enforced by a unique key), and destroying the item unequips it (`ON DELETE CASCADE`) rather than leaving a row pointing at nothing — so "consumed while equipped" is self-healing instead of a dangling reference.

---

## `Categories`

```lua
local categories = Inventory.Categories.GetCategories()
for _, category in ipairs(categories.value) do
  print(category.name, category.display_name)
end
```

These are the ledger's category tabs. Items land in a tab via `items.category_id`.

---

## Client

```lua
local Inventory = exports['feather-inventory'].initiate()

Inventory.Action.Open()                          -- the player's own book
Inventory.Action.Open(wagonUuid, 'storage')      -- paired with a container
Inventory.Action.Close()
```

The client export is deliberately thin — every mutation is server-authoritative, including which compartment an item sits in. There is no client-side API for changing inventory contents.

---

## Removed (breaking) — contract 2

The framework is alpha and does not carry backwards compatibility. **The result envelope is now the only convention**; see [Result shapes](#result-shapes). Alongside that, these surfaces existed only to avoid breaking consumers and have been removed:

| Removed | Use instead |
|---|---|
| `feather-inventory:ItemAdded` / `ItemRemoved` events | The `Feather:Inventory:*` events above |
| `Items.SetMetadata(id, patch)` | `Instances.MergeMetadata(id, patch)` |
| `inventory_items.metadata_revision` column | `row_revision`, which also moves on a move |
| `metadataRevision` field on instance reads and `SetCondition` | `revision` |
| `metadataRevision` capability flag | `instanceRevision` |
| `GetItemCount` returning `-1` on failure | Returns `nil` |
| `item_metadata` payload key on ledger item rows | `metadata` |
| `{ error = true/false }` returns on `Items`, `Inventory`, `Categories` | `{ ok, value }` / `{ ok, error }` |
| Positional multi-returns (`RegisterInventory`, `GetInventory`, …) | named tables inside `.value` |
| Generic `GrantItem` on a `unique` definition | issue it through the resource that owns it |

> **Rebuild your database for this release.** These are schema changes with no in-place migration path, by design — the framework is alpha and servers are rebuilt rather than upgraded. `metadata_revision` is simply no longer created; on a database that already has it the column is left behind, unread and unwritten. The flat `item_metadata` table is likewise removed at its source, by `feather-recipe` no longer creating it.

This resource issues no `DROP TABLE` or `DROP COLUMN` at all. It creates the columns it owns and stops creating the ones it no longer needs.

Both consumers were checked against every one of these before removal — `feather-weapons` and `feather-admin` call none of them.

## Troubleshooting

If you encounter any issues or have questions, post in our discords bugs and support channel. You may also open an issue on the issue tracker tab of GitHub.

## Contributing

Contributions to the RedM inventory script are welcome! If you have improvements or bug fixes, feel free to submit a pull request.

## License

This inventory script is licensed under GPL3 License. Refer to the LICENSE file for more information.

## Credits

Huge inspiration to RDO's inventory system with many QOL improvements.

## To-Do

The full tracked backlog — including decisions deferred or declined, with reasons — is maintained by the team outside this repository. Section references in the code comments below (`§6.1`, `§10.4`, …) point into it.

- **Hotbar** — implemented and live-tested, including the RedM `Shift+1–6` control-suppression matrix.
- **Looting** — built server-side but deliberately inert: it stays fail-closed until `feather-status`/`feather-health` provides authoritative restraint/incapacitation state. Law-enforcement and criminal resources may both consume the capability.
- **Perishables** — blocked on unique-instance support for definitions that must stack.
- **Search/filter within a book** — shipped as a themed category dropdown and search field in a two-column filter row.
- **Sound/haptic feedback** — none exists today; wants a period-fit sound-set decision first.
- **In-game item-definition editor** — ownership settled: `feather-inventory`
  owns validated preflight/write and identity-migration contracts;
  `feather-admin` owns permissioned operator UX, confirmations, and audit
  presentation. Safe catalog edits precede identity-changing migration tools.

Known gaps in the API surface above, tracked in `MASTER_PLAN.md` §6.1:

- `RunGuards` re-reads the instance on a separate connection instead of being handed the row the transaction already locked.
