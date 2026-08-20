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
        local spawnedGroundItem = Feather.Object:Create(Config.Dropped.Item, tonumber(groundItem.x), tonumber(groundItem.y), tonumber(groundItem.z), 0, true)
        spawnedGroundItem:SetAsMission()
        spawnedGroundItem:Freeze()

        local spawnedGroundItemObj = spawnedGroundItem:GetObj()

        Citizen.InvokeNative(0x7DFB49BCDB73089A, spawnedGroundItemObj, true) --SetPickupLight
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

    -- (Drop-distance bugfix) The server checks this drop position against
    -- its own cached character.x/y/z (never the client-supplied coords
    -- directly -- see server/services/ground.lua), which is correct, but
    -- that cache is only refreshed every Config.PositionSync (feather-core,
    -- 20s by default). A player who'd moved at all since the last sync
    -- would get rejected as "too far away" even standing right next to
    -- where they actually are. Forcing a fresh sync immediately before the
    -- check keeps the server-authoritative model intact -- it's just no
    -- longer working from stale data.
    -- Same call shape feather-core's own position-sync loop uses
    -- (client/services/character.lua's startPositionSync) -- passing the
    -- raw vector3 rather than a hand-built table, since the server side
    -- (RPCAPI.Register("UpdatePlayerCoords", ...)) unpacks it expecting
    -- exactly that shape.
    Feather.RPC.CallAsync("UpdatePlayerCoords", coords)

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
    local groundPrompt = PromptGroup:RegisterPrompt("Pickup", Feather.KeyCodes[Config.Dropped.PickupKey], 1, 1, true, 'hold')

    while true do
        Wait(3)
        -- (INV-21) `playerped` was undefined at this scope (only declared
        -- inside the inner loop below), so IsEntityDead(nil) was called every
        -- tick. Its BOOL return was then compared to the number 0
        -- (`isDead ~= 0`), which is true for both true and false -- the
        -- dead-check was a permanent no-op that always fell through as
        -- "alive", regardless of actual state.
        local isDead = IsEntityDead(PlayerPedId())
        if not isDead then
            if GroundItems[1] ~= nil then
                for i, item in ipairs(GroundItems) do
                    local playerped = PlayerPedId()
                    local playerCoords = GetEntityCoords(playerped)
                    local dist = Feather.Math.GetDistanceBetween(
                        vector3(playerCoords.x, playerCoords.y, playerCoords.z),
                        vector3(tonumber(item.x), tonumber(item.y), tonumber(item.z)))
                    if dist < Config.Dropped.PromptViewDistance then

                        PromptGroup:ShowGroup("Ground Items")
                        if groundPrompt:HasCompleted() then
                            Citizen.InvokeNative(0x69F4BE8C8CC4796C, playerped, item.entity:GetObj(), 3000, 2048, 3) -- TaskLookAtEntity
                            
                            local animDict =
                            "amb_rest@world_human_sketchbook_ground_pickup@male_a@react_look@exit@generic"
                            RequestAnimDict(animDict)

                            while not HasAnimDictLoaded(animDict) do
                                Wait(10)
                            end

                            -- (INV-21) TASK_PLAY_ANIM takes 13 params
                            -- (verified against the native DB); this was
                            -- calling it with 11, so `false` landed in the
                            -- `int ikFlags` slot and `taskFilter`/`p12` were
                            -- missing entirely.
                            TaskPlayAnim(playerped, animDict, "react_look_front_exit", 1.0, 8.0, -1, 1, 0, false,
                                0, false, nil, false)
                            Wait(2200)
                            ClearPedTasks(playerped)

                            OpenGroundLocation(item.id)
                        end

                        if groundPrompt:HasFailed() then
                            print("FAILED picked up!")
                        end
                    end
                end
            end
        end
    end
end)
