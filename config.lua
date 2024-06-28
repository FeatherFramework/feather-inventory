Config = {}

Config.DevMode = true

-- Opens player inventory
Config.hotkey = "B"

Config.maxItemSlots = 41          -- maximum inventory slots (last slot is your last action key)
-- Ground/Dropped item settings
Config.Dropped = {
    GroupingRadius = 10,
    PromptViewDistance = 3.0,
    PickupKey = "N",
    Item = 'p_dis_strongboxsm01x', -- options: p_package09 p_cs_baganders01x p_cs_bagstrauss01x p_bag01x p_dis_strongboxsm01x
    StreetSweep = 0 -- Deletes ALL ground inventories every X minutes from server start. If set to 0, it will clear on server start. If nil, it will never clear.
}


-- NOT IMPLEMENTED YET!
Config.maxWeight = 120000         -- Max weight a player can pickup. 120kg in grams (THIS IS NOT AVAILABLE YET)
-- Config.hotbarLimit = 6
