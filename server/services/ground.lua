function RegisterGroundInventory()
    InventoryAPI.RegisterForeignKey('ground', 'BIGINT UNSIGNED', 'id')
end

function UpdateClientWithGroundLocations(src)
    local locations = GetAllGroundLocations()
    TriggerClientEvent("Feather:Inventory:UpdateGroundLocations", src, locations)
end

-- Once a ground "inventory" gets to 0 items, it should be deleted.
Feather.RPC.Register("Feather:Inventory:GetGroundUID", function(params, res, src)
    if params.id == nil then
        error("Missing ID for ground")
        return res(nil)
    end

    local _, groundInventoryID = InventoryAPI.GetCustomInventory('ground', params.id)
    return res(groundInventoryID)
end)

Feather.RPC.Register("Feather:Inventory:DropItemsOnGround", function(params, res, src)
    local character = Feather.Character.GetCharacterBySrc(src)
    local inventoryID, _, _ = GetInventoryByCharacter(character.id)
    return res(ItemsAPI.DropItemsOnGround(inventoryID, params.items, params.x, params.y, params.z))
end)

RegisterServerEvent("Feather:Inventory:Empty", function(args)
    local location = GetInventoryLocationById(args.id)
    if location == 'ground' then
        local GID = GetGroundID(args.id)
        DeleteGround(GID)
        UpdateClientWithGroundLocations(-1)
    end
end)

RegisterServerEvent("Feather:Inventory:GetGroundLocations", function()
    local src = source
    UpdateClientWithGroundLocations(src)
end)

-- Street Sweepers Logic (Essentially a garbage collector)
CreateThread(function()
    if Config.Dropped.StreetSweep ~= nil then
        if (Config.Dropped.StreetSweep == 0) then
            DeleteAllGround()
            UpdateClientWithGroundLocations(-1)
        else
            while true do
                Citizen.Wait(Config.Dropped.StreetSweep * 60000)
                DeleteAllGround()
                UpdateClientWithGroundLocations(-1)
            end
        end
    end
end)