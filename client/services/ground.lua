-- TODO: Add LOD to load ground items within a view distance

GroundItems = {}
RegisterNetEvent("Feather:Inventory:UpdateGroundLocations", function()
    ClearGroundItems()
    GroundItems = params.locations
    SpawnGroundItems()
end)

RegisterNetEvent("Feather:Character:Spawned", function()
    TriggerServerEvent('Feather:Inventory:GetGroundLocations')
end)

function SpawnGroundItems()
    for index, groundItem in ipairs(GroundItems) do
        local spawnedGroundItem = Feather.Object:Create(Config.droppedItemObject, groundItem.x, groundItem.y, groundItem.z, 0, true)
        spawnedGroundItem:SetAsMission()
        spawnedGroundItem:Freeze()

        local spawnedGroundItemObj = spawnedGroundItem:GetObj()

        Citizen.InvokeNative(0x7DFB49BCDB73089A, spawnedGroundItemObj, true) --SetPickupLight

        -- GroundItems[index] = spawnedGroundItem
        groundItem.entity = spawnedGroundItem
    end
end

function ClearGroundItems()
    for _, groundItem in ipairs(GroundItems) do
        groundItem.entity:Remove()
    end
    GroundItems = {}
end

function OpenGroundLocation(x, y, z)
    local InventoryID = FeatherCore.RPC.CallAsync("Feather:Inventory:GetGroundUUID", {
        x = x,
        y = y,
        z = z
    })

    if InventoryID ~= nil then
        InventoryAction.Open(InventoryID)
    else
        print("Ground location not gound")
    end
end

function DropItemsOnGround(items)
    -- Get player coords but a bit in front of the player
    local playerPed = PlayerPedId()
	local coords = GetEntityCoords(playerPed, true, true)
	local forward = GetEntityForwardVector(playerPed)

    local x = coords.x + forward.x * 1.6
    local y = coords.y + forward.y * 1.6
    local z = coords.z + forward.z * 1.6

    FeatherCore.RPC.CallAsync("Feather:Inventory:DropItemsOnGround", {
        items = items,
        x = x,
        y = y,
        z = z
    })

    return true
end