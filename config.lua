Config = {}

-- (INV-05) Was `true`, shipping `/AddItems` and friends open to every
-- player by default -- free item generation for the entire economy out of
-- the box. Defaults to false now; the commands below are also
-- ACE-restricted so flipping this back on for testing doesn't hand them to
-- every player either.
Config.DevMode = false

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

    -- How long (seconds) a temporary access grant issued by a resource
    -- (e.g. this repo's own ground pickup flow) stays valid after being
    -- issued, for public/UUID-based inventories. Not re-checked on every
    -- move -- unlike a robbery target, a world object doesn't walk away.
    TemporaryGrantTTL = 60,
}
