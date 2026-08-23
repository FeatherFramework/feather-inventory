# Feather Inventory

Feather inventory is designed to provide a realistic and immersive inventory system for players. It is based on weight, allowing players to manage their items effectively. Additionally, it features a unique player-to-player robbery system and the ability to register usable items. Moreover, the script comes with an API that enables the registration of custom inventories for various entities.

## Features

1. **Player inventory**: Provides players with an inventory
2. **Secondary/Custom inventory**: Developers can utilize the API provided by the script to register custom inventories for various entities within the game. This feature allows for expanded gameplay possibilities, such as creating unique loot systems or interactive objects.
3. **Ground inventory**: A global ground inventory for when players drop items
4. **Usable Items**: The inventory system supports registering usable items, such as consumables or items that trigger specific actions when used.
5. **Custom Inventory API**: Developers can easily register custom inventories for different entities within the game, expanding the functionality of the script to cater to specific gameplay scenarios.
6. **Trusted grant API**: Server resources can list item definitions and atomically grant validated catalog items to an inventory.
7. **Item instances & versioned metadata**: Definitions are `stack` or `unique`; each owned row carries a versioned JSON metadata document with compare-and-set.
8. **Transactions**: Multi-item mutations commit atomically or not at all, with explicit conflict reporting.
9. **Movement guards & post-commit events**: Other resources can veto a move before it happens and observe every mutation after it commits.

## Getting Started

Follow these steps to set up the RedM inventory script in your server:

1. **Prerequisites**: Download the latest release from [Releases](https://github.com/DavFount/feather-inventory/releases)
2. **Installation**: Place the script files in your RedM server's resource folder. Ensure the feather-inventory in your [RESOURCE CONFIG FILE]
3. **Dependencies**: Feather Core - Feather core is the only dependency as of now.
4. **Configuration**: Adjust the settings in the configuration file to suit your server's gameplay style and preferences.
5. **Database Setup**: The database should be created for you automatically. If you are having issues please delete the table and restart the script.

---

# API Reference

Hosted documentation: [featherframework.net/api/Inventory](https://featherframework.net/api/Inventory) — note that it may lag behind this file, which is generated against the current source.

```lua
-- server
local Inventory = exports['feather-inventory'].initiate()
-- client
local Inventory = exports['feather-inventory'].initiate()
```

The server export exposes `Inventory`, `Items`, `Categories`, `Instances`, `Guards`, `Transaction` and `Diagnostics`. The client export exposes only `Action`.

## Result shapes

Two conventions exist side by side, deliberately. Newer contract surfaces (`Instances`, `Transaction`, `CanAccessInventory`) use the **result envelope**; older functions keep the shapes their existing consumers already depend on.

```lua
-- Envelope (Instances / Transaction / CanAccessInventory)
{ ok = true,  value = <result>, correlationId = <id?> }
{ ok = false, error = { code = 'stable_code', message = '...', details = {} }, correlationId = <id?> }

-- Legacy (Items / most of Inventory)
{ error = false, ... }
{ error = true, code = 'stable_code'?, message = 'English, developer-facing' }
```

`code` is stable and machine-readable; `message` is developer-facing English. Player-facing text is resolved separately from `translations/` via the matching `err_<code>` key.

> Test envelopes with `Result.IsOk(result)`, never `if result then` — a failure envelope is itself a truthy table.

Stable codes: `invalid_input`, `not_found`, `denied`, `conflict`, `unsupported`, `limit_exceeded`, `dependency_missing`, `internal`.

---

## `Inventory` — containers, capacity, access

### Registration

```lua
Inventory.Inventory.RegisterForeignKey(tableName, foreignKeyType, primaryKeyName)
Inventory.Inventory.RegisterInventory(tableName, id, displayName, ignoreItemLimits, maxWeight,
                                      restrictedItems, ownerCharacterId, isPublic, maxSlots)
  --> uuid, id
```

`RegisterInventory` notes:
- `maxWeight` — `nil` uses `Config.maxWeight`; **`0` means no weight limit** (ground piles register this way). Slot and per-item quantity limits still apply.
- `maxSlots` — `nil` uses `Config.maxItemSlots`. Capacity is per-inventory; the ledger grid scrolls, so it is not bounded by one visible page.
- `ownerCharacterId` / `isPublic` / `maxSlots` / `maxWeight` are written **only when explicitly passed** — omitting one on a re-register never resets a stored setting.

### Reads

```lua
Inventory.Inventory.GetInventory(inventoryID)
Inventory.Inventory.GetCustomInventory(key, inventoryID)   --> id, uuid, maxWeight, ignoreItemLimit
Inventory.Inventory.GetInventoryItems(inventoryID)
```

### Capacity

```lua
Inventory.Inventory.InventoryCanHold(items, inventoryId)      --> { status = boolean, code?, message }
Inventory.Inventory.InventoryCanHoldById(items, inventoryId)  --> { status = boolean, code?, message }
Inventory.Inventory.EvaluateSlotMove(fromInventory, fromSlot, toInventory, toSlot)
```

```lua
Inventory.Inventory.EvaluateInventoryAcceptance(inventory, maxWeight, ignoreItemLimit, items)
  --> { status = boolean, code?, message }
```

`items` is `{ { item = 'apple', quantity = 5 }, ... }`.

`EvaluateInventoryAcceptance` is the single definition of "can this inventory accept N of these" — quantity cap, slot capacity accounting for stacking, weight, and blacklist. The two `InventoryCanHold*` functions are thin wrappers over it that differ only in how they resolve the inventory. Call it directly when you have already resolved the inventory and its limits.

- `InventoryCanHold` takes a **player source or inventory UUID**; `InventoryCanHoldById` takes a **raw `inventory.id`**. Passing a raw id to the former is misread as a source — use the `ById` variant for ids.
- `EvaluateSlotMove` uses net-delta math (`current − leaving + arriving`) on **both** inventories, so a swap at the weight limit trading equal weights is correctly allowed.

### Open / close

```lua
Inventory.Inventory.OpenInventory(src, InventoryId, target)
Inventory.Inventory.CloseInventory(src)
Inventory.Inventory.InternalOpenInventory(src, otherInventoryId)
Inventory.Inventory.InternalCloseInventory(src)
```

### Access control

```lua
Inventory.Inventory.CanAccessInventory(src, inventoryId, action, context)  --> Result
Inventory.Inventory.IsInventoryAccessibleBySrc(src, inventoryId)          --> boolean

Inventory.Inventory.GrantInventoryAccess(src, inventoryId, targetCharacterId)
Inventory.Inventory.RevokeInventoryAccess(src, inventoryId, targetCharacterId)
Inventory.Inventory.ListInventoryAccess(src, inventoryId)
Inventory.Inventory.SetInventoryPublic(src, inventoryId, isPublic)
Inventory.Inventory.HasInventoryAccessGrant(characterId, inventoryId)
Inventory.Inventory.GetInventoryOwner(inventoryId)
Inventory.Inventory.GetInventoryOwnerAndVisibility(inventoryId)           --> ownerCharacterId, isPublic

Inventory.Inventory.GrantTemporaryAccess(src, inventoryId, ttlSeconds)
Inventory.Inventory.RevokeTemporaryAccess(src, inventoryId)
Inventory.Inventory.HasTemporaryAccess(src, inventoryId)
```

`action` is one of `Inventory.Inventory.AccessModes`: `READ`, `INSERT`, `REMOVE`, `MANAGE`. Only `MANAGE` currently resolves differently — it is owner/admin only and never granted by proximity or public visibility. A ground pile is readable and lootable by anyone near it, and manageable by nobody.

Access is re-checked on every call rather than cached, so a late mutation cannot ride a stale authorization.

---

## `Items` — grants, removal, use, condition

```lua
Inventory.Items.GetDefinitions()
Inventory.Items.ItemExists(itemName)
Inventory.Items.GetItem(id)
Inventory.Items.GetItemCount(itemName, inventoryId)
Inventory.Items.InventoryHasItems(items, inventoryId)

Inventory.Items.GrantItem(itemName, quantity, inventoryId)
  --> { error, code?, message?, itemName, displayName, quantity }
Inventory.Items.AddItem(itemName, quantity, metadata, inventoryId)
  --> { error, code?, message?, granted, requested }

Inventory.Items.RemoveItemByName(itemName, quantity, inventoryId)
Inventory.Items.RemoveItemById(id)
Inventory.Items.DropItemsOnGround(inventoryId, items, x, y, z)

Inventory.Items.RegisterUsableItem(itemName, callback)
Inventory.Items.UseItem(itemID, src)
Inventory.Items.SetMetadata(item, metadata)
```

- `GrantItem` is the **trusted** path for admin/reward/scripted flows and returns stable codes. `AddItem` is the older path; it reports `granted`/`requested` so a partial grant is distinguishable from a complete one.
- `inventoryId` follows the framework's dual convention throughout this table: **numeric = player source**, **string = inventory UUID**.

### Condition / durability

```lua
Inventory.Items.GetCondition(itemId)             --> number|nil  (nil = none recorded, not zero)
Inventory.Items.SetCondition(itemId, value)      --> { error, code?, message?, condition, metadataRevision }
Inventory.Items.AdjustCondition(itemId, delta)   --> same
```

A generic per-instance `0..Config.Condition.Max` wear value. This resource owns the **convention** — key, range, clamping, display — and none of the **policy**: when an item wears and by how much belongs to whichever resource models that behaviour.

> `SetCondition` **refuses stackable definitions** (`unsupported`). Compartments stack by `item_id`, so two units carrying different conditions would merge and lose a value. Use `instance_mode = 'unique'` for anything that carries per-instance state.

An instance with no condition recorded is treated as full by `AdjustCondition`.

---

## `Instances` — item identity and versioned metadata

```lua
Inventory.Instances.GetInstance(instanceId)     --> Result< { id, inventoryId, slot, metadata,
                                                --            metadataRevision, definition = { ... } } >
Inventory.Instances.FindInstances(inventoryId, definitionName)  --> Result< { instanceId, ... } >

Inventory.Instances.IsUniqueDefinition(itemId)  --> boolean
Inventory.Instances.SetInstanceMode(itemId, mode)  -- 'stack' | 'unique'

Inventory.Instances.ReadMetadata(instanceId)    --> Result< { document, revision } >
Inventory.Instances.WriteMetadata(instanceId, document, expectedRevision, correlationId)
                                                --> Result< { revision } >
Inventory.Instances.MergeMetadata(instanceId, patch, correlationId)
                                                --> Result< { revision } >

Inventory.Instances.GetCapabilities()           --> { version, features = { ... } }
```

- `instanceId` is the `inventory_items` row id. It is **preserved across movement** — rows are updated, never deleted and recreated — so a transferred item keeps its identity and metadata.
- Passing `expectedRevision` to `WriteMetadata` makes it a compare-and-set; a stale revision returns `conflict` with `details.expected` / `details.actual`. Omitting it is last-writer-wins.
- `MergeMetadata` is read-modify-write for a subset of keys and retries once on conflict. A `nil` value removes a key.
- Documents are capped at **4096 bytes** (`limit_exceeded`).
- `FindInstances` is scoped to one inventory on purpose — a global search would leak inventories the caller cannot access.
- `GetCapabilities` lets a dependent resource fail loudly at startup rather than mid-operation. Flags are `false` until the feature actually exists.

---

## `Transaction` — atomic multi-item mutations

```lua
Inventory.Transaction(context, function(tx)
  local weapon = tx:GetInstance(weaponInstanceId)   --> Result
  tx:SetMetadata(weaponInstanceId, nextDocument)
  tx:MoveInstance(ammoInstanceId, toInventoryId, toSlot)
  tx:DestroyInstance(spentInstanceId)
  return { loaded = rounds }
end)                                                --> Result
```

`context` is `{ actorSource, actorCharacterId, reason, correlationId, idempotencyKey, resource }`. Context improves auditability and **never grants authority** — callers still re-derive access from `source`.

How it runs: **read → validate → commit.** The read phase records each instance's revision; the validate phase is pure Lua with no writes; the commit phase submits one atomic batch. Queued writes do not touch the database until commit, so the body is safely re-runnable.

Returning a failure envelope from the body aborts without committing. Conflicts retry the whole closure (3 attempts) then return `conflict`.

> **This is optimistic concurrency, not locking.** `oxmysql` exposes no interactive transaction, so contending callers do not queue — one commits and the other is told `conflict` and retries.

```lua
Inventory.Diagnostics.GetTransactionMetrics()
  --> { started, committed, conflicts, retriesExhausted, bodyErrors, idempotentHits }
```

Conflicts are expected under optimistic concurrency; `retriesExhausted` is the number that indicates real trouble.

---

## `Guards` — vetoing movement, observing mutations

```lua
Inventory.Guards.RegisterMoveGuard(name, function(instance, context)
  if instance.metadata.equipped then
    return false, 'Unequip before moving this.'
  end
  return true
end)

Inventory.Guards.RegisterDestroyGuard(name, fn)
Inventory.Guards.UnregisterMoveGuard(name)
Inventory.Guards.UnregisterDestroyGuard(name)
```

**Guard contract:**
- Guards are **synchronous**. Do not yield — no `Wait`, no `CallAsync`, no MySQL await. A yielding guard stalls every mutation behind it.
- Return `true` to allow, or `false, reason` to veto.
- **A guard that errors is treated as a veto, not an allow.** A broken guard must not silently become permission.
- Guards hold no state, so a crashed consumer cannot wedge the inventory.
- Re-registering the same `name` replaces it, so restarts cannot accumulate duplicates.

Guards run at the chokepoints every route funnels through (bulk transfer, drag/swap, grant, delete) and, inside a transaction, at queue time — so a veto aborts before anything is written.

You can also ask the question directly, which is useful for showing a player *why* an action is unavailable before they attempt it:

```lua
Inventory.Guards.CanMoveInstance(instanceId, context)     --> boolean, reason
Inventory.Guards.CanDestroyInstance(instanceId, context)  --> boolean, reason
```

The `Emit*` functions on `Guards` are internal — this resource calls them after committing a mutation. Consumers listen for the events below rather than emitting them.

### Events

All are **internal** `TriggerEvent` and are deliberately *not* network-registered — a networked mutation event would be spoofable by any client. Listen with `AddEventHandler`.

| Event | Payload |
|---|---|
| `Feather:Inventory:ItemCreated` | `instanceId, definitionId, inventoryId, correlationId, reason` |
| `Feather:Inventory:ItemMoved` | `instanceId, fromInventoryId, toInventoryId, correlationId, reason` |
| `Feather:Inventory:ItemMetadataChanged` | `instanceId, revision, correlationId, reason` |
| `Feather:Inventory:ItemDestroyed` | `instanceId, definitionId, inventoryId, correlationId, reason` |
| `Feather:Inventory:TransactionCommitted` | `correlationId, reason, resource, summary` |

Emitted only **after** commit, so a consumer can trust that what it is told already happened.

Legacy signals `feather-inventory:ItemAdded` / `feather-inventory:ItemRemoved` (`itemId, quantity, inventoryId`) still fire alongside these for existing consumers.

---

## `Categories`

```lua
Inventory.Categories.GetCategories()
```

---

## Client

```lua
local Inventory = exports['feather-inventory'].initiate()
Inventory.Action.Open(otherInventoryId, target)
Inventory.Action.Close()
```

---

## Troubleshooting

If you encounter any issues or have questions, post in our discords bugs and support channel. You may also open an issue on the issue tracker tab of GitHub.

## Contributing

Contributions to the RedM inventory script are welcome! If you have improvements or bug fixes, feel free to submit a pull request.

## License

This inventory script is licensed under GPL3 License. Refer to the LICENSE file for more information.

## Credits

Huge inspiration to RDO's inventory system with many QOL improvements.

## To-Do

See [`MASTER_PLAN.md`](./MASTER_PLAN.md) for the full tracked backlog, including decisions that were deferred or declined with reasons.

- **Hotbar** — parked pending internal design discussion.
- **Robbery** — built server-side but deliberately inert: the statuses it gates on are client-authoritative in RedM, so it stays fail-closed until `feather-core` has an authoritative model for them.
- **Perishables** — blocked on unique-instance support for definitions that must stack.
- **Search/filter within a book** — needs a UI design decision; the ledger art has no obvious home for a text input.
- **Sound/haptic feedback** — none exists today; wants a period-fit sound-set decision first.
- **In-game item-definition editor** — ownership decision pending (`feather-inventory` API + `feather-admin` UI is the current recommendation).
