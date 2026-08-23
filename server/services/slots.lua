-- (Steampunk ledger design) Free-placement slot storage for inventory_items.
-- Self-migrates a nullable slot_index column, same pattern as
-- inventory_access.lua's EnsureAccessSchema() (owner_character_id/is_public):
-- SHOW COLUMNS + conditional ALTER TABLE, run once at startup, never touches
-- feather-recipe's migration.sql. NULL = not yet placed (shouldn't happen in
-- practice once ItemsAPI.AddItem always assigns a slot, but a row created by
-- some older/unrelated path shouldn't crash anything that reads this).
local function EnsureSlotSchema()
    local columns = MySQL.query.await("SHOW COLUMNS FROM `inventory_items` LIKE 'slot_index';")
    if #columns < 1 then
        MySQL.query.await("ALTER TABLE `inventory_items` ADD COLUMN `slot_index` SMALLINT NULL;")
    end

    -- (§10.4 per-inventory capacity) How many compartments this specific
    -- inventory has. NULL means "use Config.maxItemSlots", so every existing
    -- row keeps its current behaviour without a data migration -- capacity
    -- becomes a real per-inventory property the same way max_weight and
    -- ignore_item_limit already are, rather than one global constant that
    -- every inventory in the world had to share.
    columns = MySQL.query.await("SHOW COLUMNS FROM `inventory` LIKE 'max_slots';")
    if #columns < 1 then
        MySQL.query.await("ALTER TABLE `inventory` ADD COLUMN `max_slots` SMALLINT UNSIGNED NULL;")
    end
end

CreateThread(function()
    EnsureSlotSchema()
end)
