local function CharacterColumns()
    local rows = MySQL.query.await([[
        SELECT `TABLE_NAME`, `COLUMN_NAME`, `DATA_TYPE`, `CHARACTER_MAXIMUM_LENGTH`
        FROM information_schema.COLUMNS
        WHERE `TABLE_SCHEMA` = DATABASE() AND (
            (`TABLE_NAME` = 'inventory' AND `COLUMN_NAME` IN ('character_id', 'owner_character_id')) OR
            (`TABLE_NAME` = 'inventory_access' AND `COLUMN_NAME` IN ('character_id', 'granted_by_character_id')) OR
            (`TABLE_NAME` = 'character_equipment' AND `COLUMN_NAME` = 'character_id')
        )
    ]]) or {}
    local columns = {}
    for _, row in ipairs(rows) do
        columns[row.TABLE_NAME .. '.' .. row.COLUMN_NAME] = row
    end
    return columns
end

local function SchemaUsesUuidColumns()
    local columns = CharacterColumns()
    local required = {
        'inventory.character_id', 'inventory.owner_character_id',
        'inventory_access.character_id', 'inventory_access.granted_by_character_id',
        'character_equipment.character_id'
    }
    for _, name in ipairs(required) do
        local column = columns[name]
        if not column or column.DATA_TYPE ~= 'char' or tonumber(column.CHARACTER_MAXIMUM_LENGTH) ~= 36 then
            return false, name
        end
    end
    return true
end

local function LegacyForeignKeyCount()
    return tonumber(MySQL.scalar.await([[
        SELECT COUNT(*) FROM information_schema.KEY_COLUMN_USAGE
        WHERE `TABLE_SCHEMA` = DATABASE()
          AND `TABLE_NAME` IN ('inventory', 'inventory_access', 'character_equipment')
          AND `REFERENCED_TABLE_NAME` = 'characters'
    ]])) or 0
end

RegisterCommand('InvCharacterUuidSmokeTest', function(source, args)
    if source ~= 0 then return end
    local target = tonumber(args and args[1])
    if not target then
        local players = GetPlayers()
        target = players[1] and tonumber(players[1]) or nil
    end

    local schemaOk, invalidColumn = SchemaUsesUuidColumns()
    local session = target and InventoryIdentity.GetSession(target)
        or Result.Err(Result.Codes.NOT_FOUND, 'No connected player is available.')
    local uuid = MySQL.scalar.await('SELECT UUID()')
    local roundTrip
    if schemaOk then
        local created = InventoryAPI.RegisterInventory('character', uuid, 'UUID Smoke')
        local inventoryId = Result.IsOk(created) and InventoryControllers.GetInventoryByCharacter(uuid) or nil
        roundTrip = Result.IsOk(created) and inventoryId ~= false
        MySQL.query.await('DELETE FROM `inventory` WHERE `character_id` = ?', { uuid })
    else
        roundTrip = false
    end

    local tests = {
        { name = 'uuid column schema', passed = schemaOk, detail = invalidColumn },
        { name = 'legacy foreign keys removed', passed = LegacyForeignKeyCount() == 0 },
        { name = 'uuid normalization', passed = InventoryIdentity.NormalizeCharacterId(uuid) == uuid:lower() },
        { name = 'numeric identity rejected', passed = InventoryIdentity.NormalizeCharacterId(123) == nil },
        { name = 'current session resolved', passed = Result.IsOk(session),
            detail = target and ('source=' .. tostring(target)) or 'no player' },
        { name = 'uuid inventory round trip', passed = roundTrip == true }
    }
    local passed = 0
    for _, test in ipairs(tests) do
        if test.passed then passed = passed + 1 end
        print(('[InvCharacterUuidSmokeTest] %-28s %s%s'):format(
            test.name, test.passed and 'PASS' or 'FAIL', test.detail and ('  -- ' .. test.detail) or ''))
    end
    print(('[InvCharacterUuidSmokeTest] done %d/%d passed'):format(passed, #tests))
end, true)
