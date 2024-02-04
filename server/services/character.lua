function RegisterCharacterStart(InventoryAPI)
    RegisterServerEvent("Feather:Character:Spawned", function(character)
        InventoryAPI.Inventory.RegisterInventory('character', character.id)
    end)
end