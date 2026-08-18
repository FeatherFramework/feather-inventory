-- Wires inventory creation into the character spawn lifecycle: every time a
-- character spawns, ensures it has a linked inventory row (creates one on
-- first spawn, no-ops on later spawns -- see InventoryAPI.RegisterInventory
-- in server/services/inventory.lua). Called once from StartAPI() in
-- server/services/api.lua.
--
-- (INV-13) This used to listen on the networked "Feather:Character:Spawned"
-- event, which any client can call directly via TriggerServerEvent with a
-- forged character.id -- letting an attacker link an inventory row to any
-- character id, not just their own. feather-core now fires an internal,
-- non-networked "Feather:Server:Character:Spawned" signal from the server
-- itself, after it has already re-verified ownership -- see
-- feather-core/server/services/character.lua's InitiateCharacter.
function RegisterCharacterStart(InventoryAPI)
    EnsureCharacterInventoryUnique()

    AddEventHandler("Feather:Server:Character:Spawned", function(character)
        InventoryAPI.Inventory.RegisterInventory('character', character.id)
    end)
end

-- (INV-13) Belt-and-braces even with the signal de-networked: guarantees at
-- most one inventory row per character at the schema level, so a second
-- RegisterInventory('character', id) call for the same id can never produce
-- a duplicate/colliding row regardless of caller.
function EnsureCharacterInventoryUnique()
    local existing = MySQL.query.await(
        "SELECT INDEX_NAME FROM information_schema.STATISTICS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'inventory' AND INDEX_NAME = 'UQ_InventoryCharacter';"
    )
    if #existing < 1 then
        MySQL.query.await("ALTER TABLE `inventory` ADD UNIQUE KEY `UQ_InventoryCharacter` (`character_id`);")
    end
end
