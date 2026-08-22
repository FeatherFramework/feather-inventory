-- (INV-11/INV-12/INV-23) Authorization layer for opening an inventory that
-- isn't your own. Loads after inventory.lua (alphabetical server_scripts
-- glob order -- InventoryAPI must already exist as a table).
--
-- Two independent gates, matched to the two legitimate ways this happens:
--
--   1. Owned/shared inventories (storage, saddlebags, job lockers) -- gated
--      by ownership (`inventory.owner_character_id`) or a persistent
--      per-character grant (`inventory_access`), or, for inventories the
--      owner has marked public, a short-lived grant issued by whichever
--      resource disclosed the inventory's UUID after checking whatever
--      condition it's responsible for (see GrantTemporaryAccess).
--   2. Another player's own character inventory (robbery / forced search)
--      -- gated by proximity AND the target being in a status that
--      justifies it (unconscious, hogtied, cuffed, ...).
--
-- Previously, InternalOpenInventory (server/services/inventory.lua) treated
-- the act of a client asking for an inventory as authorization to open it --
-- it self-registered the lock that the access check then trusted. Every
-- function below exists so authorization comes from state the *client*
-- cannot set: a persisted grant only the inventory's owner/an admin can
-- create, a temporary grant only another server-side resource can create, or
-- a status flag only feather-core (once it implements one) can set.

------------------------------------------------------------------
-- Status (robbery / forced search gate)
------------------------------------------------------------------

-- Lua has no enum type -- this is a plain table of named string constants
-- so call sites read as `LootableStatuses.Cuffed` instead of a bare string,
-- and so the set of reasons is defined in exactly one place.
--
-- Tracking *which* status a character is actually in is feather-core's job,
-- not feather-inventory's -- this table only says which of core's status
-- names feather-inventory is willing to accept as justification to let
-- another player open this character's inventory without consent.
LootableStatuses = {
    Unconscious = 'unconscious',
    Hogtied     = 'hogtied',
    Cuffed      = 'cuffed',
    Restrained  = 'restrained',
}

---
-- Can Be Looted Due To Status
--
-- DEPENDENCY: feather-core does not implement character status tracking as
-- of this writing. Feather.Character.HasStatus is called defensively --
-- if it isn't a function (core hasn't shipped it yet), this returns false.
-- That is a deliberate fail-closed default: the robbery/forced-search path
-- stays inert until core provides real status tracking, rather than this
-- resource inventing its own notion of character state to fill the gap.
--
-- @param characterId Target character's id
-- @return True if any status feather-inventory treats as "lootable" is set
--
function CanBeLootedDueToStatus(characterId)
    if not characterId then
        return false
    end

    if type(Feather.Character.HasStatus) ~= 'function' then
        return false
    end

    for _, status in pairs(LootableStatuses) do
        if Feather.Character.HasStatus(characterId, status) then
            return true
        end
    end

    return false
end

------------------------------------------------------------------
-- Proximity (robbery / forced search gate)
------------------------------------------------------------------

local function GetCharacterPosition(src)
    local player = Feather.Character.GetCharacter({ src = src })
    local character = player and player.char
    if not character or not character.x or not character.y or not character.z then
        return nil
    end
    return tonumber(character.x), tonumber(character.y), tonumber(character.z)
end

local function IsWithinDistance(x1, y1, z1, x2, y2, z2, maxDistance)
    if not (x1 and y1 and z1 and x2 and y2 and z2) then
        return false
    end
    local dx, dy, dz = x1 - x2, y1 - y2, z1 - z2
    return (dx * dx + dy * dy + dz * dz) <= (maxDistance * maxDistance)
end

---
-- Is Within Robbery Distance
--
-- True if src is currently near the character behind targetSrc's ped, per
-- both sides' server-cached position. That position is client-reported and
-- only as fresh as the last UpdatePlayerCoords RPC (~CORE-32 caveat) -- this
-- is a bound on distance, not a live guarantee, but strictly better than no
-- check at all, which is what INV-11/INV-12 shipped with.
--
-- @param src Caller's player source
-- @param targetSrc Target player's source
-- @return True if within Config.Access.RobberyDistance
--
function IsWithinRobberyDistance(src, targetSrc)
    local x1, y1, z1 = GetCharacterPosition(src)
    local x2, y2, z2 = GetCharacterPosition(targetSrc)
    return IsWithinDistance(x1, y1, z1, x2, y2, z2, Config.Access.RobberyDistance)
end

---
-- Is Within Give Distance
--
-- Same shape as IsWithinRobberyDistance -- see its comment for the
-- server-cached-position caveat -- bound to Config.Access.GiveDistance
-- instead. Used by GiveItem (server/services/callbacks.lua), which
-- previously had no server-side distance check at all.
--
-- @param src Caller's player source
-- @param targetSrc Target player's source
-- @return True if within Config.Access.GiveDistance
--
function IsWithinGiveDistance(src, targetSrc)
    local x1, y1, z1 = GetCharacterPosition(src)
    local x2, y2, z2 = GetCharacterPosition(targetSrc)
    return IsWithinDistance(x1, y1, z1, x2, y2, z2, Config.Access.GiveDistance)
end

------------------------------------------------------------------
-- Owned/shared inventory ACL (storage, saddlebags, job lockers, ...)
------------------------------------------------------------------

local function EnsureAccessSchema()
    local columns = MySQL.query.await("SHOW COLUMNS FROM `inventory` LIKE 'owner_character_id';")
    if #columns < 1 then
        MySQL.query.await([[
            ALTER TABLE `inventory`
            ADD COLUMN `owner_character_id` BIGINT UNSIGNED NULL,
            ADD CONSTRAINT `FK_InventoryOwner` FOREIGN KEY (`owner_character_id`) REFERENCES `characters` (`id`) ON DELETE SET NULL ON UPDATE CASCADE;
        ]])
    end

    columns = MySQL.query.await("SHOW COLUMNS FROM `inventory` LIKE 'is_public';")
    if #columns < 1 then
        MySQL.query.await("ALTER TABLE `inventory` ADD COLUMN `is_public` TINYINT(1) NOT NULL DEFAULT 0;")
    end

    MySQL.query.await([[
        CREATE TABLE IF NOT EXISTS `inventory_access` (
            `id` BIGINT UNSIGNED NOT NULL PRIMARY KEY AUTO_INCREMENT,
            `inventory_id` BIGINT UNSIGNED NOT NULL,
            `character_id` BIGINT UNSIGNED NOT NULL,
            `granted_by_character_id` BIGINT UNSIGNED NULL,
            `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
            UNIQUE KEY `UQ_InventoryAccess` (`inventory_id`, `character_id`),
            CONSTRAINT `FK_InventoryAccessInventory` FOREIGN KEY (`inventory_id`) REFERENCES `inventory` (`id`) ON DELETE CASCADE,
            CONSTRAINT `FK_InventoryAccessCharacter` FOREIGN KEY (`character_id`) REFERENCES `characters` (`id`) ON DELETE CASCADE
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
    ]])
end

CreateThread(function()
    EnsureAccessSchema()
end)

local function GetOwnCharacterId(src)
    local player = Feather.Character.GetCharacter({ src = src })
    local character = player and player.char
    return character and character.id
end

local function IsOwnerOrAdmin(src, ownerCharacterId)
    local callerCharacterId = GetOwnCharacterId(src)
    if callerCharacterId and ownerCharacterId and tostring(callerCharacterId) == tostring(ownerCharacterId) then
        return true
    end
    return type(Feather.Character.IsAdmin) == 'function' and Feather.Character.IsAdmin(src) == true
end

InventoryAPI.GetInventoryOwner = function(inventoryId)
    local result = MySQL.query.await('SELECT `owner_character_id` FROM `inventory` WHERE `id`=? LIMIT 1;', { inventoryId })[1]
    return result and result.owner_character_id
end

InventoryAPI.GetInventoryOwnerAndVisibility = function(inventoryId)
    local result = MySQL.query.await('SELECT `owner_character_id`, `is_public` FROM `inventory` WHERE `id`=? LIMIT 1;', { inventoryId })[1]
    if not result then
        return nil, false
    end
    return result.owner_character_id, Boolean[result.is_public] == true
end

InventoryAPI.HasInventoryAccessGrant = function(characterId, inventoryId)
    if not characterId or not inventoryId then
        return false
    end
    local result = MySQL.query.await(
        'SELECT `id` FROM `inventory_access` WHERE `inventory_id`=? AND `character_id`=? LIMIT 1;',
        { inventoryId, characterId }
    )[1]
    return result ~= nil
end

---
-- Grant Inventory Access / Revoke Inventory Access / Set Inventory Public / List Inventory Access
--
-- Only the inventory's owner or an admin may manage its access list or
-- public flag -- re-derived server-side from `src` every call, never
-- trusted from the client.
--
InventoryAPI.GrantInventoryAccess = function(src, inventoryId, targetCharacterId)
    local ownerCharacterId = InventoryAPI.GetInventoryOwner(inventoryId)
    if not ownerCharacterId then
        return { error = true, message = 'This inventory has no owner and cannot have its access list managed.' }
    end
    if not IsOwnerOrAdmin(src, ownerCharacterId) then
        return { error = true, message = 'You do not own this inventory.' }
    end

    MySQL.query.await(
        'INSERT IGNORE INTO `inventory_access` (`inventory_id`, `character_id`, `granted_by_character_id`) VALUES (?, ?, ?);',
        { inventoryId, targetCharacterId, GetOwnCharacterId(src) }
    )
    return { error = false }
end

InventoryAPI.RevokeInventoryAccess = function(src, inventoryId, targetCharacterId)
    local ownerCharacterId = InventoryAPI.GetInventoryOwner(inventoryId)
    if not IsOwnerOrAdmin(src, ownerCharacterId) then
        return { error = true, message = 'You do not own this inventory.' }
    end

    MySQL.query.await(
        'DELETE FROM `inventory_access` WHERE `inventory_id`=? AND `character_id`=?;',
        { inventoryId, targetCharacterId }
    )
    return { error = false }
end

InventoryAPI.SetInventoryPublic = function(src, inventoryId, isPublic)
    local ownerCharacterId = InventoryAPI.GetInventoryOwner(inventoryId)
    if not IsOwnerOrAdmin(src, ownerCharacterId) then
        return { error = true, message = 'You do not own this inventory.' }
    end

    MySQL.query.await('UPDATE `inventory` SET `is_public`=? WHERE `id`=?;', { isPublic and 1 or 0, inventoryId })
    return { error = false }
end

InventoryAPI.ListInventoryAccess = function(src, inventoryId)
    local ownerCharacterId = InventoryAPI.GetInventoryOwner(inventoryId)
    if not IsOwnerOrAdmin(src, ownerCharacterId) then
        return { error = true, message = 'You do not own this inventory.' }
    end

    return {
        error = false,
        characters = MySQL.query.await(
            'SELECT `character_id`, `granted_by_character_id`, `created_at` FROM `inventory_access` WHERE `inventory_id`=?;',
            { inventoryId }
        )
    }
end

------------------------------------------------------------------
-- Temporary access grants (public/UUID inventories -- ground pickups, etc.)
------------------------------------------------------------------

local TemporaryGrants = {} -- [tostring(src)][tostring(inventoryId)] = expiresAt (GetGameTimer() ms)

---
-- Grant Temporary Access
--
-- Called by another server-side resource (or another file in this one --
-- see ground.lua's GetGroundUID) after it has independently verified
-- whatever condition justifies src opening this inventory right now
-- (proximity to a world object, a consent flow, ...). feather-inventory
-- does not know or care why -- it only tracks that the grant exists and
-- expires, and only ever honours it for inventories the owner has marked
-- `is_public` (see IsAuthorizedForOwnedInventory below).
--
-- @param src Player source being granted access
-- @param inventoryId Raw inventory.id
-- @param ttlSeconds How long the grant is valid for (default Config.Access.TemporaryGrantTTL)
--
InventoryAPI.GrantTemporaryAccess = function(src, inventoryId, ttlSeconds)
    if not src or not inventoryId then
        return
    end
    local key = tostring(src)
    TemporaryGrants[key] = TemporaryGrants[key] or {}
    TemporaryGrants[key][tostring(inventoryId)] = GetGameTimer() + ((tonumber(ttlSeconds) or Config.Access.TemporaryGrantTTL) * 1000)
end

InventoryAPI.RevokeTemporaryAccess = function(src, inventoryId)
    local grants = TemporaryGrants[tostring(src)]
    if grants then
        grants[tostring(inventoryId)] = nil
    end
end

InventoryAPI.HasTemporaryAccess = function(src, inventoryId)
    local grants = TemporaryGrants[tostring(src)]
    local expiresAt = grants and grants[tostring(inventoryId)]
    local now = GetGameTimer()
    if Config.Debug then
        local keys = {}
        if grants then
            for k in pairs(grants) do table.insert(keys, k) end
        end
        DebugPrint('DEBUG-ACCESS', 'HasTemporaryAccess: src=%s inventoryId=%s expiresAt=%s now=%s grantKeysForSrc=[%s]',
            tostring(src), tostring(inventoryId), tostring(expiresAt), tostring(now), table.concat(keys, ', '))
    end
    return expiresAt ~= nil and expiresAt > now
end

AddEventHandler('playerDropped', function()
    TemporaryGrants[tostring(source)] = nil
end)

------------------------------------------------------------------
-- Combined authorization check used by InternalOpenInventory
------------------------------------------------------------------

---
-- Is Authorized For Owned Inventory
--
-- @param src Caller's player source
-- @param callerCharacterId Caller's own character id
-- @param inventoryId Raw inventory.id being requested (UUID already resolved)
-- @return True if src may open this inventory right now
--
function IsAuthorizedForOwnedInventory(src, callerCharacterId, inventoryId)
    local ownerCharacterId, isPublic = InventoryAPI.GetInventoryOwnerAndVisibility(inventoryId)
    local hasGrant = InventoryAPI.HasInventoryAccessGrant(callerCharacterId, inventoryId)
    local hasTemp = InventoryAPI.HasTemporaryAccess(src, inventoryId)
    DebugPrint('DEBUG-ACCESS', 'IsAuthorizedForOwnedInventory: src=%s callerCharacterId=%s inventoryId=%s owner=%s isPublic=%s hasAccessGrant=%s hasTemporaryAccess=%s',
        tostring(src), tostring(callerCharacterId), tostring(inventoryId), tostring(ownerCharacterId), tostring(isPublic), tostring(hasGrant), tostring(hasTemp))

    if ownerCharacterId and callerCharacterId and tostring(ownerCharacterId) == tostring(callerCharacterId) then
        return true
    end

    if hasGrant then
        return true
    end

    -- (Public-access simplification) `is_public` used to still require a
    -- short-lived temp grant on top -- meaningful for a resource that wants
    -- to disclose one specific inventory to one specific player for a
    -- moment, but ground piles have no privacy concern at all: there's
    -- nothing to gate beyond "were you near it," which GetGroundUID already
    -- checks server-side before a client can even learn the UUID at all.
    -- Public now means public -- no additional expiring grant required.
    if isPublic then
        return true
    end

    -- Kept for non-public disclosed-UUID cases a future resource might
    -- still want (see InventoryAPI.GrantTemporaryAccess's doc comment) --
    -- just no longer required for is_public=true inventories specifically.
    if hasTemp then
        return true
    end

    return false
end
