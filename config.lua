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

-- (Steampunk ledger) The book art is a fixed 574x983 asset calibrated for
-- an exact 5x5 grid -- unlike the old panel UI, this design has no room to
-- grow past that without either scrolling (not part of the design) or
-- shrinking every compartment (breaks the "pixel for pixel" fidelity the
-- handoff calls for). 25 is no longer just a display preference, it's the
-- book's real physical capacity now.
Config.maxItemSlots = 25          -- maximum inventory slots
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


Config.maxWeight = 120000         -- Default inventory weight limit in grams (120 kg).
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
