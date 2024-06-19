-- TODO: Add LOD to load ground items within a view distance

GroundItems = {}
RegisterNetEvent("Feather:Inventory:UpdateGroundLocations", function(locations)
    ClearGroundItems()
    GroundItems = locations
    SpawnGroundItems()
end)

RegisterNetEvent("Feather:Character:Spawned", function()
    TriggerServerEvent('Feather:Inventory:GetGroundLocations')
end)

function SpawnGroundItems()
    for index, groundItem in ipairs(GroundItems) do
        local spawnedGroundItem = Feather.Object:Create(nil, tonumber(groundItem.x), tonumber(groundItem.y), tonumber(groundItem.z), 0, true)

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

function OpenGroundLocation(id)
    local InventoryID = Feather.RPC.CallAsync("Feather:Inventory:GetGroundUID", {
        id = id
    })

    if InventoryID ~= nil and InventoryID ~= false then
        InventoryAction.Open(InventoryID)
    else
        print("Ground location not found")
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

    local result = Feather.RPC.CallAsync("Feather:Inventory:DropItemsOnGround", {
        items = items,
        x = x,
        y = y,
        z = z
    })
    return result
end

CreateThread(function()
    local PromptGroup = Feather.Prompt:SetupPromptGroup()
    local groundPrompt = PromptGroup:RegisterPrompt("Pickup", Feather.KeyCodes[Config.pickupKey], 1, 1, true, 'hold')

    while true do
        Wait(5)
        local isDead = IsEntityDead(playerped)
        if isDead ~= 0 then
            if GroundItems[1] ~= nil then
                -- local closest = {
                --     dist = 99999999
                -- }

                for i, item in ipairs(GroundItems) do
                    local playerped = PlayerPedId()
                    local playerCoords = GetEntityCoords(playerped)
                    local dist = Feather.Math.GetDistanceBetween(
                        vector3(playerCoords.x, playerCoords.y, playerCoords.z),
                        vector3(tonumber(item.x), tonumber(item.y), tonumber(item.z)))
                    if dist < Config.dropPromptViewDistance then
                        -- if dist <= closest.dist then
                        --     closest = {
                        --         dist = dist
                        --     }

                            Citizen.InvokeNative(0x69F4BE8C8CC4796C, playerped, item.entity:GetObj(), 3000, 2048, 3) -- TaskLookAtEntity

                            PromptGroup:ShowGroup("Ground Items")
                            if groundPrompt:HasCompleted() then
                                

                                -- local animDict =
                                -- "amb_rest@world_human_sketchbook_ground_pickup@male_a@react_look@exit@generic"
                                -- RequestAnimDict(animDict)

                                -- while not HasAnimDictLoaded(animDict) do
                                --     Wait(10)
                                -- end

                                -- TaskPlayAnim(playerped, animDict, "react_look_front_exit", 1.0, 8.0, -1, 1, 0, false,
                                --     false, false)
                                -- Wait(2200)
                                -- ClearPedTasks(playerped)

                                OpenGroundLocation(item.id)

                                -- closest = {
                                --     dist = 99999999
                                -- }
                            end

                            if groundPrompt:HasFailed() then
                                print("FAILED picked up!")
                            end
                        -- end
                    end
                end
            end
        end
    end
end)
