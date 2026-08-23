Config = {}

-- (INV-05) Was `true`, shipping `/AddItems` and friends open to every
-- player by default -- free item generation for the entire economy out of
-- the box. Defaults to false now; the commands below are also
-- ACE-restricted so flipping this back on for testing doesn't hand them to
-- every player either.
Config.DevMode = false

-- Gates verbose server-console logging (currently the access/ground
-- resolution tracing added while building the robbery/ACL system) --
-- separate from DevMode, which gates security-sensitive item-spawn
-- commands. Leave false in production; flip on to trace access decisions.
Config.Debug = false

-- Opens player inventory
Config.hotkey = "I"

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
Config.maxItemSlots = 40          -- default inventory slots, overridable per inventory
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
    Item = 'p_dis_strongboxsm01x', -- options: p_package09 p_cs_baganders01x p_cs_bagstrauss01x p_bag01x p_dis_strongboxsm01x
    StreetSweep = 0 -- Deletes ALL ground inventories every X minutes from server start. If set to 0, it will clear on server start. If nil, it will never clear.
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
-- Config.hotbarLimit = 6

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
