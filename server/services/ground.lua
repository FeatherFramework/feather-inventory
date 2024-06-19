function RegisterGroundInventory()
    InventoryAPI.RegisterForeignKey('ground', 'BIGINT UNSIGNED', 'id')
end

function UpdateClientWithGroundLocations(src)
    local locations = GroundControllers.GetAllGroundLocations()
    TriggerClientEvent("Feather:Inventory:UpdateGroundLocations", src, locations)
end

Feather.RPC.Register("Feather:Inventory:GetGroundUID", function(params, res, src)
    if params.id == nil then
        error("Missing ID for ground")
        return res(nil)
    end
    local _, groundInventoryID = InventoryAPI.GetCustomInventory('ground', params.id)
    return res(groundInventoryID)
end)

-- Feather:Inventory:UpdateGroundLocations
Feather.RPC.Register("Feather:Inventory:DropItemsOnGround", function(params, res, src)
    local character = Feather.Character.GetCharacterBySrc(src)
    local inventoryID, _, _ = InventoryControllers.GetInventoryByCharacter(character.id)
    return res(ItemsAPI.DropItemsOnGround(inventoryID, params.items, params.x, params.y, params.z))
end)

RegisterServerEvent("Feather:Inventory:GetGroundLocations", function()
    local src = source
    UpdateClientWithGroundLocations(src)
end)