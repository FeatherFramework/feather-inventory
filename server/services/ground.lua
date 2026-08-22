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
        warn("Missing ID for ground")
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
        DebugPrint('DEBUG-GROUND', 'GetGroundUID: no inventory row for ground.id=%s', tostring(params.id))
        return res(nil)
    end

    -- (Public-access simplification) Ground inventories are `is_public = true`,
    -- and IsAuthorizedForOwnedInventory now grants access on that flag alone --
    -- the proximity check above is the only gate that actually matters here.
    -- No temporary grant needed for the caller to open what this returns.
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

    -- (INV-17) x/y/z used to go straight from the client into CreateGround
    -- with no check at all -- an attacker could seed ground piles (and, per
    -- INV-12's fix, only reachably lootable ones) anywhere on the map,
    -- including out-of-bounds coordinates the `ground` table's numeric
    -- columns reject. Bound the drop to near the caller's own server-known
    -- position, same radius GetGroundUID already requires to pick a pile
    -- back up.
    if type(params.x) ~= 'number' or type(params.y) ~= 'number' or type(params.z) ~= 'number' then
        return res({ error = true, message = 'Invalid drop location.' })
    end
    if not character.x or not character.y or not character.z then
        return res({ error = true, message = 'No character loaded.' })
    end
    local dx, dy, dz = tonumber(character.x) - params.x, tonumber(character.y) - params.y, tonumber(character.z) - params.z
    local maxDistance = Config.Dropped.PromptViewDistance + 1.0 -- small buffer for position staleness (~CORE-32)
    if (dx * dx + dy * dy + dz * dz) > (maxDistance * maxDistance) then
        Feather.Notify.RightNotify(src, 'You are too far away.', 3000)
        return res({ error = true, message = 'You are too far away.' })
    end

    local inventoryID, _, _ = InventoryControllers.GetInventoryByCharacter(character.id)
    -- (§10.1 rejection-surfacing) DropItemsOnGround already returns a real
    -- {error, message} on capacity rejection (INV-14) -- it just never
    -- reached the player; the NUI only logged it to the browser console.
    local dropResult = ItemsAPI.DropItemsOnGround(inventoryID, params.items, params.x, params.y, params.z)
    if dropResult and dropResult.error then
        Feather.Notify.RightNotify(src, dropResult.message or 'Unable to drop items.', 3000)
    end
    return res(dropResult)
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
        -- (Ground cleanup bugfix) This deleted the world-position row but
        -- left the inventory row itself (args.id) sitting in the DB
        -- forever -- orphaned rows accumulate with every emptied pile.
        InventoryControllers.DeleteInventoryById(args.id)
        UpdateClientWithGroundLocations(-1)
    end
end)

RegisterServerEvent("Feather:Inventory:GetGroundLocations", function()
    local src = source
    UpdateClientWithGroundLocations(src)
end)

-- Street Sweepers Logic (Essentially a garbage collector)
--
-- (Ground cleanup bugfix) Wiping `ground` (world positions) without also
-- clearing the `inventory` rows pointing at `location = 'ground'` left every
-- one of them orphaned -- on a server with StreetSweep = 0 (the default),
-- this meant a fresh, empty `inventory` row got left behind on every single
-- restart, forever. Worse: RegisterInventory looks up an existing inventory
-- by ground_id before creating a new one, so if a freshly created ground
-- row's auto-increment id ever coincided with an old orphaned row's
-- ground_id, a brand new drop could silently reuse that stale row instead
-- of getting its own.
CreateThread(function()
    if Config.Dropped.StreetSweep ~= nil then
        if (Config.Dropped.StreetSweep == 0) then
            GroundControllers.DeleteAllGround()
            InventoryControllers.DeleteInventoriesByLocation('ground')
            UpdateClientWithGroundLocations(-1)
        else
            while true do
                Wait(Config.Dropped.StreetSweep * 60000)
                GroundControllers.DeleteAllGround()
                InventoryControllers.DeleteInventoriesByLocation('ground')
                UpdateClientWithGroundLocations(-1)
            end
        end
    end
end)