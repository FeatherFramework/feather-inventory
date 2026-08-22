-- (§10.2 ground LOD) Keyed by tostring(id) rather than an array index --
-- reconciled in place on every server update instead of being wholesale
-- cleared and rebuilt, so a pile the player is nowhere near doesn't get
-- despawned and respawned every time *any* pile changes *anywhere* on the
-- map (which the old unconditional Clear+Spawn did, for every online
-- player, on every single drop/pickup/empty). `entity` is nil until the LOD
-- thread below actually spawns it.
GroundItems = {}

RegisterNetEvent("Feather:Inventory:UpdateGroundLocations", function(locations)
    local seen = {}
    for _, loc in ipairs(locations) do
        local key = tostring(loc.id)
        seen[key] = true
        local existing = GroundItems[key]
        if existing then
            -- Same pile, refresh its coords; keep whatever entity state
            -- (spawned or not) the LOD thread already has for it.
            existing.x, existing.y, existing.z = loc.x, loc.y, loc.z
        else
            GroundItems[key] = { id = loc.id, x = loc.x, y = loc.y, z = loc.z, entity = nil }
        end
    end

    -- A pile that's gone from the server's list (fully looted/swept) --
    -- despawn its entity if it had one and drop it from the table.
    for key, item in pairs(GroundItems) do
        if not seen[key] then
            if item.entity then
                item.entity:Remove()
            end
            GroundItems[key] = nil
        end
    end
end)

RegisterNetEvent("Feather:Character:Spawned", function()
    TriggerServerEvent('Feather:Inventory:GetGroundLocations')
end)

function SpawnGroundItemEntity(item)
    local spawnedGroundItem = Feather.Object:Create(Config.Dropped.Item, tonumber(item.x), tonumber(item.y), tonumber(item.z), 0, true)
    spawnedGroundItem:SetAsMission()
    spawnedGroundItem:Freeze()

    Citizen.InvokeNative(0x7DFB49BCDB73089A, spawnedGroundItem:GetObj(), true) --SetPickupLight

    return spawnedGroundItem
end

-- (§10.2 ground LOD) Spawns/despawns each pile's prop based on the player's
-- own live distance to it. A 1s tick is plenty for a prop appearing/
-- disappearing at LoadDistance -- this isn't the pickup-eligibility check
-- (that's the tighter, 3ms loop further down using PromptViewDistance).
CreateThread(function()
    while true do
        Wait(1000)
        local playerCoords = GetEntityCoords(PlayerPedId())
        for _, item in pairs(GroundItems) do
            local dist = Feather.Math.GetDistanceBetween(
                playerCoords, vector3(tonumber(item.x), tonumber(item.y), tonumber(item.z)))
            if dist <= Config.Dropped.LoadDistance then
                if not item.entity then
                    item.entity = SpawnGroundItemEntity(item)
                end
            elseif item.entity then
                item.entity:Remove()
                item.entity = nil
            end
        end
    end
end)

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
        -- (§10.2 ground LOD) GroundItems is now keyed by id (pairs), not a
        -- dense array (ipairs) -- see the reconciliation rewrite above. An
        -- item this close should already be spawned by the 1s LOD thread
        -- (PromptViewDistance is always < LoadDistance, enforced in
        -- errors.lua), but `item.entity` is guarded anyway rather than
        -- assumed non-nil for the one tick right after a pile first comes
        -- into pickup range, before that thread's next pass catches up.
        if not isDead then
            for _, item in pairs(GroundItems) do
                if item.entity then
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
