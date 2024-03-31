function RegisterGroundInventory(InventoryAPI)
    InventoryAPI.RegisterForeignKey('ground', 'BIGINT UNSIGNED', 'id')
end

function UpdateClientWithGroundLocations(src)
    local locations = GetAllGroundLocations()
    TriggerClientEvent("Feather:Inventory:UpdateGroundLocations", src, locations)
end

Feather.RPC.Register("Feather:Inventory:GetGroundUUID", function(params, res, src)
    local groundID = GetClosestGroundByCoords(params.x, params.y, params.z, Config.groundGroupingRadius)

    if groundID == nil then
        return res(nil)
    end

    local groundInventoryUID = InventoryAPI.RegisterInventory('ground', groundID)
    return res(groundInventoryUID)
end)

-- Feather:Inventory:UpdateGroundLocations
Feather.RPC.Register("Feather:Inventory:DropItemsOnGround", function(params, res, src)
    ItemsAPI.DropPlayerItemsOnGround(src, params.items, params.x, params.y, params.z)
    return res(true)
end)

RegisterServerEvent("Feather:Inventory:GetGroundLocations", function()
    local src = source
    UpdateClientWithGroundLocations(src)
end)