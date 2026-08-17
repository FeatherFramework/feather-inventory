function RegisterGroundInventory()
    InventoryAPI.RegisterForeignKey('ground', 'BIGINT UNSIGNED', 'id')
end

function UpdateClientWithGroundLocations(src)
    local locations = GroundControllers.GetAllGroundLocations()
    TriggerClientEvent("Feather:Inventory:UpdateGroundLocations", src, locations)
end

-- Once a ground "inventory" gets to 0 items, it should be deleted.
--
-- (INV-12) Previously handed back the ground pile's inventory UUID to any
-- caller, unconditionally -- the only proximity check anywhere in this flow
-- was client-side (the pickup prompt loop). A client could request the UID
-- for any pile id on the map regardless of distance. Ground inventories are
-- registered `is_public = true` (see items.lua's DropItemsOnGround), so a
-- bare UUID is not enough to open one -- this now verifies the caller is
-- actually standing near the pile server-side before issuing the
-- short-lived grant that InternalOpenInventory requires.
Feather.RPC.Register("Feather:Inventory:GetGroundUID", function(params, res, src)
    if params.id == nil then
        error("Missing ID for ground")
        return res(nil)
    end

    local player = Feather.Character.GetCharacter({ src = src })
    local character = player and player.char
    if not character or not character.x or not character.y or not character.z then
        return res(nil)
    end

    local groundX, groundY, groundZ = GroundControllers.GetGroundById(params.id)
    local dx, dy, dz = tonumber(character.x) - groundX, tonumber(character.y) - groundY, tonumber(character.z) - groundZ
    local maxDistance = Config.Dropped.PromptViewDistance + 1.0 -- small buffer for position staleness (~CORE-32)
    if (dx * dx + dy * dy + dz * dz) > (maxDistance * maxDistance) then
        Feather.Notify.RightNotify(src, 'You are too far away.', 3000)
        return res(nil)
    end

    local groundInventoryId, groundInventoryUUID = InventoryAPI.GetCustomInventory('ground', params.id)
    if not groundInventoryId then
        return res(nil)
    end

    InventoryAPI.GrantTemporaryAccess(src, groundInventoryId, Config.Access.TemporaryGrantTTL)
    return res(groundInventoryUUID)
end)

Feather.RPC.Register("Feather:Inventory:DropItemsOnGround", function(params, res, src)
    -- (Phase 6 consistency pass) No nil-guard here meant any client without
    -- a loaded character crashed this RPC on `character.id` instead of
    -- getting a clean rejection.
    local player = Feather.Character.GetCharacter({ src = src })
    local character = player and player.char
    if not character then
        return res({ error = true, message = 'No character loaded.' })
    end

    local inventoryID, _, _ = InventoryControllers.GetInventoryByCharacter(character.id)
    return res(ItemsAPI.DropItemsOnGround(inventoryID, params.items, params.x, params.y, params.z))
end)

-- (INV-04) Was a RegisterServerEvent, making it network-reachable -- any
-- client could call it directly with an arbitrary inventory id and delete
-- someone else's ground drop. The only real caller is the internal
-- TriggerEvent in InternalCloseInventory (server/services/inventory.lua),
-- so this is de-networked to AddEventHandler: it still fires for that
-- internal signal, but a client's TriggerServerEvent can no longer reach it
-- since the event name was never registered as network-enabled.
AddEventHandler("Feather:Inventory:Empty", function(args)
    local location = InventoryControllers.GetInventoryLocationById(args.id)
    if location == 'ground' then
        local GID = GroundControllers.GetGroundID(args.id)
        GroundControllers.DeleteGround(GID)
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
            GroundControllers.DeleteAllGround()
            UpdateClientWithGroundLocations(-1)
        else
            while true do
                Wait(Config.Dropped.StreetSweep * 60000)
                GroundControllers.DeleteAllGround()
                UpdateClientWithGroundLocations(-1)
            end
        end
    end
end)