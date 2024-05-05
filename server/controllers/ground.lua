function GetGroundById(id)
    local result = MySQL.query.await(
        'SELECT `x`, `y`, `z` FROM `ground` WHERE `id` = ? LIMIT 1;', { id })[1]
    if not result then
        return 0, 0, 0
    end
    return result.x, result.y, result.z
end

function GetAllGroundLocations()
    return MySQL.query.await(
        'SELECT `id`, `x`, `y`, `z` FROM `ground`;')
end

function GetClosestGroundByCoords(x, y, z, radius)
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

function CreateGround(x, y, z)
    return MySQL.query.await('INSERT INTO `ground` (`x`, `y`, `z`) VALUES (?, ?, ?) RETURNING *;',
        { x, y, z })
end

function DeleteGround(id)
    print("SHOULD DELETE NOW", id)
    MySQL.query.await('DELETE FROM `ground` WHERE `id` = ?;', { id })
end

function DeleteGround(id)
    MySQL.query.await('DELETE FROM `ground` WHERE `id` = ?;', { id })
end

function DeleteAllGround()
    MySQL.query.await('DELETE FROM `ground`;')
end

function GetGroundID(id)
    local result = MySQL.query.await(
        'SELECT `ground_id` FROM `inventory` WHERE `id` = ? LIMIT 1;', { id })[1]
    if not result then
        return 0, 0, 0
    end
    return result.ground_id
end
