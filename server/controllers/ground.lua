-- Raw DB access for the `ground` table -- world coordinates of dropped-item
-- piles. Each row pairs 1:1 with an `inventory` row of location='ground'
-- (see InventoryAPI.RegisterInventory), which is what actually holds the
-- items; this table only exists to answer "where in the world is this pile."
GroundControllers = {}

function GroundControllers.GetGroundById(id, query)
    query = query or DefaultQuery
    local result = query(
        'SELECT `x`, `y`, `z` FROM `ground` WHERE `id` = ? LIMIT 1;', { id })[1]
    if not result then
        return 0, 0, 0
    end
    return result.x, result.y, result.z
end

function GroundControllers.GetAllGroundLocations()
    return DB.query(
        'SELECT `id`, `x`, `y`, `z` FROM `ground`;')
end

-- Startup cleanup needs exact instance ids so it can use DestroyInstances and
-- emit one post-commit destruction fact per item instead of silently relying
-- on the ground -> inventory -> inventory_items foreign-key cascade.
function GroundControllers.GetGroundCleanupRows()
    return DB.query([[
        SELECT g.`id` AS `ground_id`, i.`id` AS `inventory_id`,
               ii.`id` AS `instance_id`
        FROM `ground` g
        LEFT JOIN `inventory` i
          ON i.`ground_id`=g.`id` AND i.`location`='ground'
        LEFT JOIN `inventory_items` ii ON ii.`inventory_id`=i.`id`
        ORDER BY g.`id`, i.`id`, ii.`id`;
    ]])
end

-- Finds an existing ground pile within `radius` of (x,y,z), if any -- used
-- by DropItemsOnGround (server/services/items.lua) to merge nearby drops
-- into one pile instead of creating a new one for every drop.
--
-- (feather-mysql migration) Rewritten from oxmysql's named parameters
-- (`@x`/`@y`/`@z`/`@radius`, each reused across both the WHERE and ORDER BY
-- clauses) to positional `?` placeholders, which feather-mysql's DB.* only
-- supports -- `@name` has no special meaning to it and would either error or
-- silently reference an unrelated, unset MySQL session variable (always NULL,
-- which would make the WHERE clause match nothing, every time). x/y/z are
-- passed twice because each appears in both clauses.
function GroundControllers.GetClosestGroundByCoords(x, y, z, radius)
    local result = DB.query([[
        SELECT id
        FROM ground
        WHERE SQRT(POW(x - ?, 2) + POW(y - ?, 2) + POW(z - ?, 2)) <= ?
        ORDER BY SQRT(POW(x - ?, 2) + POW(y - ?, 2) + POW(z - ?, 2))
        LIMIT 1;
    ]], x, y, z, radius, x, y, z)[1]

    if not result then
        return nil
    end

    return result.id
end

function GroundControllers.CreateGround(x, y, z)
    return DB.query('INSERT INTO `ground` (`x`, `y`, `z`) VALUES (?, ?, ?) RETURNING *;',
        x, y, z)
end

-- (feather-mysql migration) DB.exec returns the affected-row count directly
-- as a number, not an { affectedRows, ... } object the way the transaction-
-- bound tx.raw adapter does elsewhere in this resource -- these two functions
-- read the count directly rather than through a field that would no longer exist.
function GroundControllers.DeleteGroundIfEmpty(id)
    local affected = DB.exec([[
        DELETE FROM `ground`
        WHERE `id`=? AND NOT EXISTS (
            SELECT 1 FROM `inventory` i
            INNER JOIN `inventory_items` ii ON ii.`inventory_id`=i.`id`
            WHERE i.`ground_id`=`ground`.`id`
            LIMIT 1
        );
    ]], id)
    return (tonumber(affected) or 0) == 1
end

function GroundControllers.DeleteEmptyGround()
    local affected = DB.exec([[
        DELETE FROM `ground`
        WHERE NOT EXISTS (
            SELECT 1 FROM `inventory` i
            INNER JOIN `inventory_items` ii ON ii.`inventory_id`=i.`id`
            WHERE i.`ground_id`=`ground`.`id`
            LIMIT 1
        );
    ]])
    return tonumber(affected) or 0
end

function GroundControllers.GetGroundID(id, query)
    query = query or DefaultQuery
    local result = query(
        'SELECT `ground_id` FROM `inventory` WHERE `id` = ? LIMIT 1;', { id })[1]
    if not result then
        return nil
    end
    return result.ground_id
end
