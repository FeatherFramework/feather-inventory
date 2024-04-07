Config = {}


Config.hotkey = "B"

Config.maxItemSlots = 41          -- maximum inventory slots (last slot is your last action key)
Config.maxWeight = 120000         -- Max weight a player can pickup. 120kg in grams

-- Ground/Dropped item settings
Config.groundGroupingRadius = 10
Config.maxDropViewDistance = 12.5 -- Max distance to see a dropped item
Config.dropPromptViewDistance = 3.0
Config.pickupKey = "N"
Config.droppedItemObject = 'p_dis_strongboxsm01x'
-- p_cs_baganders01x (left)
-- p_cs_bagstrauss01x (middle)
-- p_bag01x (right)
-- p_dis_strongboxsm01x (front center)

Config.hotbarLimit = 6 -- NOT YET IMPLEMENTED


-- TODO:
    -- Store in statebag for any entity creating inventory
    -- Inventory ID (e.g. 25)
    -- Inventory ID as Hash (e.g. b7a56873cd771f2c446d369b649430b65a756ba278ff97ec81bb6f55b2e73569)

    -- Compare when attempting access
