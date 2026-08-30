-- Raw DB access for the `ground` table -- world coordinates of dropped-item
-- piles. Each row pairs 1:1 with an `inventory` row of location='ground'
-- (see InventoryAPI.RegisterInventory), which is what actually holds the
-- items; this table only exists to answer "where in the world is this pile."
GroundControllers = {}

function GroundControllers.GetGroundById(id)
    local result = MySQL.query.await(
        'SELECT `x`, `y`, `z` FROM `ground` WHERE `id` = ? LIMIT 1;', { id })[1]
    if not result then
        return 0, 0, 0
    end
    return result.x, result.y, result.z
end

function GroundControllers.GetAllGroundLocations()
    return MySQL.query.await(
        'SELECT `id`, `x`, `y`, `z` FROM `ground`;')
end

-- Finds an existing ground pile within `radius` of (x,y,z), if any -- used
-- by DropItemsOnGround (server/services/items.lua) to merge nearby drops
-- into one pile instead of creating a new one for every drop.
function GroundControllers.GetClosestGroundByCoords(x, y, z, radius)
    local result = MySQL.query.await([[
        SELECT id
        FROM ground
        WHERE SQRT(POW(x - @x, 2) + POW(y - @y, 2) + POW(z - @z, 2)) <= @radius
        ORDER BY SQRT(POW(x - @x, 2) + POW(y - @y, 2) + POW(z - @z, 2))
        LIMIT 1;
    ]], {
        ['x'] = x,
        ['y'] = y,
        ['z'] = z,
        ['radius'] = radius
    })[1]

    if not result then
        return nil
    end

    return result.id
end

function GroundControllers.CreateGround(x, y, z)
    return MySQL.query.await('INSERT INTO `ground` (`x`, `y`, `z`) VALUES (?, ?, ?) RETURNING *;',
        { x, y, z })
end

function GroundControllers.DeleteGroundIfEmpty(id)
    local result = MySQL.query.await([[
        DELETE FROM `ground`
        WHERE `id`=? AND NOT EXISTS (
            SELECT 1 FROM `inventory` i
            INNER JOIN `inventory_items` ii ON ii.`inventory_id`=i.`id`
            WHERE i.`ground_id`=`ground`.`id`
            LIMIT 1
        );
    ]], { id })
    return (tonumber(result and (result.affectedRows or result.affected_rows)) or 0) == 1
end

function GroundControllers.DeleteEmptyGround()
    local result = MySQL.query.await([[
        DELETE FROM `ground`
        WHERE NOT EXISTS (
            SELECT 1 FROM `inventory` i
            INNER JOIN `inventory_items` ii ON ii.`inventory_id`=i.`id`
            WHERE i.`ground_id`=`ground`.`id`
            LIMIT 1
        );
    ]])
    return tonumber(result and (result.affectedRows or result.affected_rows)) or 0
end

function GroundControllers.GetGroundID(id)
    local result = MySQL.query.await(
        'SELECT `ground_id` FROM `inventory` WHERE `id` = ? LIMIT 1;', { id })[1]
    if not result then
        return nil
    end
    return result.ground_id
end
