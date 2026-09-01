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

    local x, y, z = InventoryIdentity.GetPosition(src)
    if not x then
        return res(nil)
    end

    local groundX, groundY, groundZ = GroundControllers.GetGroundById(params.id)
    local dx, dy, dz = x - groundX, y - groundY, z - groundZ
    local maxDistance = Config.Dropped.PromptViewDistance + 1.0 -- small buffer for position staleness (~CORE-32)
    if (dx * dx + dy * dy + dz * dz) > (maxDistance * maxDistance) then
        Feather.Notify.RightNotify(src, Translate(src, 'err_too_far', 'You are too far away.'), 3000)
        return res(nil)
    end

    local found = InventoryAPI.GetCustomInventory('ground', params.id)
    if not Result.IsOk(found) then
        DebugPrint('DEBUG-GROUND', 'GetGroundUID: no inventory row for ground.id=%s', tostring(params.id))
        return res(nil)
    end
    local groundInventoryId = found.value.id
    local groundInventoryUUID = found.value.uuid

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
    local player = InventoryIdentity.GetCharacter(src)
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
    local x, y, z = InventoryIdentity.GetPosition(src)
    if not x then
        return res({ error = true, message = 'No character loaded.' })
    end
    local dx, dy, dz = x - params.x, y - params.y, z - params.z
    local maxDistance = Config.Dropped.PromptViewDistance + 1.0 -- small buffer for position staleness (~CORE-32)
    if (dx * dx + dy * dy + dz * dz) > (maxDistance * maxDistance) then
        Feather.Notify.RightNotify(src, Translate(src, 'err_too_far', 'You are too far away.'), 3000)
        return res({ error = true, message = 'You are too far away.' })
    end

    local inventoryID, _, _ = InventoryControllers.GetInventoryByCharacter(character.id)
    -- (§10.1 rejection-surfacing) DropItemsOnGround already returns a real
    -- {error, message} on capacity rejection (INV-14) -- it just never
    -- reached the player; the NUI only logged it to the browser console.
    local dropResult = ItemsAPI.DropItemsOnGround(inventoryID, params.items, params.x, params.y, params.z, {
        actorSource = src,
        actorCharacterId = character.id,
        reason = 'ground_drop',
        resource = 'feather-inventory'
    })
    if not Result.IsOk(dropResult) then
        Feather.Notify.RightNotify(src, TranslateResult(src, dropResult, 'err_drop_failed'), 3000)
        return res({ error = true, code = dropResult.error.code, message = dropResult.error.message })
    end
    return res({ error = false, inv = dropResult.value.inventory })
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
        -- Recheck emptiness in the DELETE itself. If another drop reached this
        -- pile after CloseInventory observed it empty, the pile and its new
        -- contents survive instead of being cascade-deleted.
        if GID and GroundControllers.DeleteGroundIfEmpty(GID) then
            UpdateClientWithGroundLocations(-1)
        end
    end
end)

RegisterServerEvent("Feather:Inventory:GetGroundLocations", function()
    local src = source
    UpdateClientWithGroundLocations(src)
end)

local function ClearGroundOnStart()
    local pilesById, pileOrder = {}, {}
    for _, row in ipairs(GroundControllers.GetGroundCleanupRows() or {}) do
        local groundId = tonumber(row.ground_id)
        if groundId and not pilesById[groundId] then
            pilesById[groundId] = {
                groundId = groundId,
                inventoryId = tonumber(row.inventory_id),
                instanceIds = {}
            }
            pileOrder[#pileOrder + 1] = groundId
        end
        local pile = groundId and pilesById[groundId]
        local instanceId = tonumber(row.instance_id)
        if pile and instanceId then
            pile.instanceIds[#pile.instanceIds + 1] = instanceId
        end
    end

    local clearedPiles, destroyedItems, failedPiles = 0, 0, 0
    for _, groundId in ipairs(pileOrder) do
        local pile = pilesById[groundId]
        local mayDelete = #pile.instanceIds == 0
        if not mayDelete and pile.inventoryId then
            local destroyed = TransactionAPI.DestroyInstances({
                reason = 'ground_restart_cleanup',
                resource = GetCurrentResourceName()
            }, {
                inventoryId = pile.inventoryId,
                expectedLocation = 'ground',
                instanceIds = pile.instanceIds
            })
            mayDelete = Result.IsOk(destroyed)
            if mayDelete then
                destroyedItems = destroyedItems + #pile.instanceIds
            else
                failedPiles = failedPiles + 1
                local failureMessage = destroyed and destroyed.error and destroyed.error.message
                    or 'unknown destruction failure'
                warn(('Ground startup cleanup preserved pile %s because item destruction failed: %s')
                    :format(tostring(groundId), tostring(failureMessage)))
            end
        end

        if mayDelete and GroundControllers.DeleteGroundIfEmpty(groundId) then
            clearedPiles = clearedPiles + 1
        elseif mayDelete then
            failedPiles = failedPiles + 1
            warn(('Ground startup cleanup could not delete pile %s after clearing its contents.')
                :format(tostring(groundId)))
        end
    end

    print(('[feather-inventory] Ground startup cleanup: %d pile(s), %d item instance(s) cleared; %d pile(s) preserved after failure.')
        :format(clearedPiles, destroyedItems, failedPiles))
end

-- Ground property is intentionally ephemeral. Startup cleanup explicitly
-- destroys each exact instance (and emits normal destruction facts) before
-- deleting the empty pile. Timed street sweeping remains empty-row GC only.
CreateThread(function()
    if Config.Dropped.ClearOnStart == true then
        ClearGroundOnStart()
    end

    if Config.Dropped.StreetSweep ~= nil then
        if (Config.Dropped.StreetSweep == 0) then
            GroundControllers.DeleteEmptyGround()
            UpdateClientWithGroundLocations(-1)
        else
            while true do
                Wait(Config.Dropped.StreetSweep * 60000)
                GroundControllers.DeleteEmptyGround()
                UpdateClientWithGroundLocations(-1)
            end
        end
    end
end)
