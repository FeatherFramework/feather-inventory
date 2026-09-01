Config = {}

-- (INV-05) Was `true`, shipping `/AddItems` and friends open to every
-- player by default -- free item generation for the entire economy out of
-- the box. Keep enabled during pre-release development; switch this to false
-- for the first production release. The commands below are also ACE-restricted
-- so enabling it for testing does not hand them to every player.
Config.DevMode = true

-- Gates verbose server-console logging (currently the access/ground
-- resolution tracing added while building the robbery/ACL system) --
-- separate from DevMode, which gates security-sensitive item-spawn
-- commands. Leave false in production; flip on to trace access decisions.
Config.Debug = false

-- Opens player inventory
Config.hotkey = "I"

-- Player hotbar. Enabled is enforced on both client input/rendering and the
-- server use path. Visibility accepts Temporary, Always, or UserDefined; only
-- UserDefined exposes the Temporary/Always preference in feather-settings.
Config.Hotbar = {
    Enabled = true,
    Visibility = 'UserDefined',
    -- Used only when Visibility is UserDefined and the player has not saved a
    -- preference yet. This must resolve to an actual display mode.
    DefaultVisibility = 'Temporary',
    -- Player-adjustable HUD opacity starts here until a local preference is
    -- saved through feather-settings.
    DefaultOpacity = 90,
    TemporaryDuration = 4000,
    Modifier = 'SHIFT',
    Slots = 6,
}

-- (§10.4) The DEFAULT compartment count, used by any inventory that doesn't
-- register a capacity of its own. Capacity is per-inventory now
-- (`inventory.max_slots`, nullable -- see RegisterInventory's maxSlots
-- parameter), so a storage wagon can be genuinely larger than a player's
-- book instead of every container in the world sharing this one number.
--
-- The book art is still a fixed 574x983 asset calibrated for a 5x5 page, and
-- that hasn't changed -- what changed is that the compartment grid inside it
-- scrolls (the surrounding chrome stays pinned), so capacity is no longer
-- bounded by what fits on one visible page.
--
-- 40 is 8 rows at 5 columns, so a default inventory shows one full page and
-- scrolls to reach the remaining 3 rows. (25 would be exactly one page and
-- never scroll -- fine, but it leaves the scrolling path untested in normal
-- play, and makes the default book smaller than the design now supports.)
Config.maxItemSlots = 40 -- default inventory slots, overridable per inventory
-- Ground/Dropped item settings
Config.Dropped = {
    GroupingRadius = 10,
    PromptViewDistance = 3.0,
    -- (§10.2 ground LOD) Max distance a ground pile's prop is actually
    -- spawned/kept loaded for a given client -- previously every dropped
    -- item on the whole map was spawned for every player, and re-spawned
    -- for everyone on every single drop/pickup anywhere (see client/
    -- services/ground.lua's old UpdateGroundLocations handler, which
    -- unconditionally cleared and respawned the full list on every update).
    -- Must stay well above PromptViewDistance -- the pickup prompt loop
    -- assumes an in-range pile's entity is already spawned.
    LoadDistance = 40.0,
    PickupKey = "N",
    -- Holding Pickup first walks the player to the local prop. The inventory
    -- only opens after they reach this distance; blocked paths time out.
    WalkToPickup = true,
    WalkSpeed = 1.0,
    -- Interaction radius around the prop. Keep this outside the strongbox's
    -- collision envelope or the ped stops physically but never satisfies the
    -- arrival check.
    WalkStopDistance = 1.25,
    WalkTimeout = 6000,
    Item = 'p_dis_strongboxsm01x', -- options: p_package09 p_cs_baganders01x p_cs_bagstrauss01x p_bag01x p_dis_strongboxsm01x
    -- Ground is temporary world state. On every feather-inventory resource
    -- start, destroy its exact item instances through the audited transaction
    -- API, then remove the empty pile/container rows.
    ClearOnStart = true,
    -- Garbage-collects EMPTY ground piles every X minutes. 0 runs once at
    -- startup; nil disables the periodic empty-pile sweep.
    StreetSweep = 0
}


-- Default inventory weight limit, in POUNDS. Overridable per inventory via
-- RegisterInventory's maxWeight parameter (`inventory.max_weight`).
--
-- Was 120000, documented as grams -- but the ledger has always rendered this
-- line with an "lb." suffix, so the two never agreed, and 120000 of anything
-- meant the limit was unreachable in practice. Pounds is the unit that
-- actually gets displayed, and 125 lb is a defensible load for a person on
-- foot in 1901.
--
-- NOTE: `items.weight` is an INTEGER column, so the smallest expressible
-- weight is 1 lb. That sets the granularity of everything below -- there is
-- no half-pound item without a schema change.
Config.maxWeight = 125

-- (§10.3) Item condition / durability.
--
-- A generic, per-instance 0..Max wear value stored in `item_metadata` under
-- `Key`. Inventory owns the CONVENTION -- the key, the range, clamping, and
-- how a value is displayed -- and deliberately owns none of the policy:
-- deciding that firing a gun costs 1 condition, or that a repair kit restores
-- 40, belongs to whichever resource models that behaviour. Doing it once here
-- generically is strictly better than feather-weapons, a tools resource and a
-- clothing resource each inventing their own field.
--
-- Stages drive the wear label shown in the ledger, highest first; `at` is the
-- minimum condition value for that stage. Purely presentational -- change
-- them freely, no server logic reads them.
Config.Condition = {
    Key = 'condition',
    Max = 100,
    Stages = {
        { at = 80, label = 'ui_condition_pristine' },
        { at = 50, label = 'ui_condition_worn' },
        { at = 20, label = 'ui_condition_damaged' },
        { at = 0,  label = 'ui_condition_ruined' },
    }
}
-- (INV-11/INV-12/INV-23) Access control for opening an inventory that isn't
-- your own -- see server/services/access.lua.
Config.Access = {
    -- Max distance (world units) between two players' server-cached
    -- positions to open one's inventory from the other -- robbery/forced
    -- search. Checked at open time and re-checked on every subsequent move.
    RobberyDistance = 3.0,

    -- Max distance (world units) between two players' server-cached
    -- positions for GiveItem -- separate from RobberyDistance since giving
    -- is consensual, not a forced-search context, but the same "actually
    -- standing near each other" requirement applies. Previously unchecked
    -- server-side; the client only aimed at whoever GetPedInFront() found.
    GiveDistance = 3.0,

    -- How long (seconds) a temporary access grant issued by a resource
    -- (e.g. this repo's own ground pickup flow) stays valid after being
    -- issued, for public/UUID-based inventories. Not re-checked on every
    -- move -- unlike a robbery target, a world object doesn't walk away.
    TemporaryGrantTTL = 60,
}
