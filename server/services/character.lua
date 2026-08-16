-- Wires inventory creation into the character spawn lifecycle: every time a
-- character spawns, ensures it has a linked inventory row (creates one on
-- first spawn, no-ops on later spawns -- see InventoryAPI.RegisterInventory
-- in server/services/inventory.lua). Called once from StartAPI() in
-- server/services/api.lua. Note this listens on the same networked
-- Feather:Character:Spawned event the client re-broadcasts (see feather-core
-- CHAR-01 fix) -- `character` here is only used for its `.id`, not trusted
-- for anything else.
function RegisterCharacterStart(InventoryAPI)
    RegisterServerEvent("Feather:Character:Spawned", function(character)
        InventoryAPI.Inventory.RegisterInventory('character', character.id)
    end)
end