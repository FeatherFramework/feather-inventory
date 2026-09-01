DiagnosticsAPI = DiagnosticsAPI or {}

local function TableExists(name)
    return (tonumber(MySQL.scalar.await([[
        SELECT COUNT(*) FROM information_schema.TABLES
        WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME=?;
    ]], { name })) or 0) > 0
end

local function NewReport(sampleLimit)
    local report = {
        dryRun = true,
        generatedAt = os.time(),
        sampleLimit = sampleLimit,
        summary = { totalFindings = 0, byCode = {}, bySeverity = {} },
        findings = {},
        truncatedByCode = {},
    }

    function report:add(code, severity, details)
        self.summary.totalFindings = self.summary.totalFindings + 1
        self.summary.byCode[code] = (self.summary.byCode[code] or 0) + 1
        self.summary.bySeverity[severity] = (self.summary.bySeverity[severity] or 0) + 1
        local sampled = 0
        for _, finding in ipairs(self.findings) do
            if finding.code == code then sampled = sampled + 1 end
        end
        if sampled < self.sampleLimit then
            self.findings[#self.findings + 1] = {
                code = code,
                severity = severity,
                details = details,
            }
        else
            self.truncatedByCode[code] = (self.truncatedByCode[code] or 0) + 1
        end
    end

    return report
end

local function AddRows(report, code, severity, rows)
    for _, row in ipairs(rows or {}) do report:add(code, severity, row) end
end

--- Read-only inventory integrity scan. This function contains SELECTs only;
-- it intentionally has no repair mode or dynamic mutation callback.
local function RunIntegrityDiagnostics(options)
    options = options or {}
    local sampleLimit = math.floor(tonumber(options.sampleLimit) or 50)
    sampleLimit = math.max(1, math.min(sampleLimit, 500))
    local report = NewReport(sampleLimit)

    AddRows(report, 'orphan_instance_inventory', 'critical', MySQL.query.await([[
        SELECT ii.`id` AS `instanceId`, ii.`inventory_id` AS `inventoryId`
        FROM `inventory_items` ii LEFT JOIN `inventory` inv ON inv.`id`=ii.`inventory_id`
        WHERE inv.`id` IS NULL ORDER BY ii.`id`;
    ]]))

    AddRows(report, 'missing_definition', 'critical', MySQL.query.await([[
        SELECT ii.`id` AS `instanceId`, ii.`item_id` AS `definitionId`,
               ii.`inventory_id` AS `inventoryId`
        FROM `inventory_items` ii LEFT JOIN `items` i ON i.`id`=ii.`item_id`
        WHERE i.`id` IS NULL ORDER BY ii.`id`;
    ]]))

    AddRows(report, 'archived_definition_in_use', 'info', MySQL.query.await([[
        SELECT i.`id` AS `definitionId`, i.`name` AS `itemName`,
               COUNT(ii.`id`) AS `ownedInstances`
        FROM `items` i INNER JOIN `inventory_items` ii ON ii.`item_id`=i.`id`
        WHERE i.`archived_at` IS NOT NULL
        GROUP BY i.`id`, i.`name` ORDER BY i.`id`;
    ]]))

    AddRows(report, 'malformed_metadata', 'error', MySQL.query.await([[
        SELECT `id` AS `instanceId`, `inventory_id` AS `inventoryId`
        FROM `inventory_items`
        WHERE `metadata` IS NOT NULL AND JSON_VALID(`metadata`)=0 ORDER BY `id`;
    ]]))

    AddRows(report, 'invalid_slot', 'error', MySQL.query.await([[
        SELECT ii.`id` AS `instanceId`, ii.`inventory_id` AS `inventoryId`,
               ii.`slot_index` AS `slot`, COALESCE(NULLIF(inv.`max_slots`, 0), ?) AS `capacity`
        FROM `inventory_items` ii INNER JOIN `inventory` inv ON inv.`id`=ii.`inventory_id`
        WHERE ii.`slot_index` IS NULL OR ii.`slot_index` < 0
           OR ii.`slot_index` >= COALESCE(NULLIF(inv.`max_slots`, 0), ?)
        ORDER BY ii.`inventory_id`, ii.`id`;
    ]], { Config.maxItemSlots, Config.maxItemSlots }))

    AddRows(report, 'mixed_definition_slot', 'critical', MySQL.query.await([[
        SELECT `inventory_id` AS `inventoryId`, `slot_index` AS `slot`,
               COUNT(*) AS `units`, COUNT(DISTINCT `item_id`) AS `definitions`
        FROM `inventory_items` WHERE `slot_index` IS NOT NULL
        GROUP BY `inventory_id`, `slot_index`
        HAVING COUNT(DISTINCT `item_id`) > 1
        ORDER BY `inventory_id`, `slot_index`;
    ]]))

    AddRows(report, 'unique_definition_stacked', 'critical', MySQL.query.await([[
        SELECT ii.`inventory_id` AS `inventoryId`, ii.`slot_index` AS `slot`,
               ii.`item_id` AS `definitionId`, i.`name` AS `itemName`, COUNT(*) AS `units`
        FROM `inventory_items` ii INNER JOIN `items` i ON i.`id`=ii.`item_id`
        WHERE ii.`slot_index` IS NOT NULL AND i.`instance_mode`='unique'
        GROUP BY ii.`inventory_id`, ii.`slot_index`, ii.`item_id`, i.`name`
        HAVING COUNT(*) > 1 ORDER BY ii.`inventory_id`, ii.`slot_index`;
    ]]))

    AddRows(report, 'stack_size_exceeded', 'error', MySQL.query.await([[
        SELECT ii.`inventory_id` AS `inventoryId`, ii.`slot_index` AS `slot`,
               ii.`item_id` AS `definitionId`, COUNT(*) AS `units`,
               i.`max_stack_size` AS `limit`
        FROM `inventory_items` ii INNER JOIN `items` i ON i.`id`=ii.`item_id`
        WHERE ii.`slot_index` IS NOT NULL
        GROUP BY ii.`inventory_id`, ii.`slot_index`, ii.`item_id`, i.`max_stack_size`
        HAVING COUNT(*) > i.`max_stack_size`
        ORDER BY ii.`inventory_id`, ii.`slot_index`;
    ]]))

    -- Semantic JSON equality is deliberately done through the same helper as
    -- placement. SQL textual equality would falsely flag reordered object keys.
    local stackRows = MySQL.query.await([[
        SELECT ii.`inventory_id`, ii.`slot_index`, ii.`id`, ii.`metadata`
        FROM `inventory_items` ii
        INNER JOIN (
            SELECT `inventory_id`, `slot_index` FROM `inventory_items`
            WHERE `slot_index` IS NOT NULL
            GROUP BY `inventory_id`, `slot_index` HAVING COUNT(*) > 1
        ) stacks ON stacks.`inventory_id`=ii.`inventory_id`
            AND stacks.`slot_index`=ii.`slot_index`
        ORDER BY ii.`inventory_id`, ii.`slot_index`, ii.`id`;
    ]]) or {}
    local currentKey, currentRows
    local function inspectStack()
        if currentRows and not InventoryMetadata.RowsCompatible(currentRows) then
            report:add('metadata_incompatible_stack', 'critical', {
                inventoryId = tonumber(currentRows[1].inventory_id),
                slot = tonumber(currentRows[1].slot_index),
                units = #currentRows,
            })
        end
    end
    for _, row in ipairs(stackRows) do
        local key = tostring(row.inventory_id) .. ':' .. tostring(row.slot_index)
        if key ~= currentKey then
            inspectStack()
            currentKey, currentRows = key, {}
        end
        currentRows[#currentRows + 1] = row
    end
    inspectStack()

    AddRows(report, 'inventory_over_slot_capacity', 'error', MySQL.query.await([[
        SELECT inv.`id` AS `inventoryId`, COUNT(DISTINCT ii.`slot_index`) AS `occupiedSlots`,
               COALESCE(NULLIF(inv.`max_slots`, 0), ?) AS `capacity`
        FROM `inventory` inv INNER JOIN `inventory_items` ii ON ii.`inventory_id`=inv.`id`
        WHERE ii.`slot_index` IS NOT NULL
        GROUP BY inv.`id`, inv.`max_slots`
        HAVING COUNT(DISTINCT ii.`slot_index`) > COALESCE(NULLIF(inv.`max_slots`, 0), ?)
        ORDER BY inv.`id`;
    ]], { Config.maxItemSlots, Config.maxItemSlots }))

    AddRows(report, 'inventory_overweight', 'error', MySQL.query.await([[
        SELECT inv.`id` AS `inventoryId`, SUM(i.`weight`) AS `weight`,
               COALESCE(inv.`max_weight`, ?) AS `limit`
        FROM `inventory` inv
        INNER JOIN `inventory_items` ii ON ii.`inventory_id`=inv.`id`
        INNER JOIN `items` i ON i.`id`=ii.`item_id`
        GROUP BY inv.`id`, inv.`max_weight`
        HAVING COALESCE(inv.`max_weight`, ?) > 0
           AND SUM(i.`weight`) > COALESCE(inv.`max_weight`, ?)
        ORDER BY inv.`id`;
    ]], { Config.maxWeight, Config.maxWeight, Config.maxWeight }))

    AddRows(report, 'definition_quantity_exceeded', 'error', MySQL.query.await([[
        SELECT ii.`inventory_id` AS `inventoryId`, ii.`item_id` AS `definitionId`,
               COUNT(*) AS `quantity`, i.`max_quantity` AS `limit`
        FROM `inventory_items` ii
        INNER JOIN `items` i ON i.`id`=ii.`item_id`
        INNER JOIN `inventory` inv ON inv.`id`=ii.`inventory_id`
        WHERE COALESCE(inv.`ignore_item_limit`, 0)=0 AND i.`max_quantity` > 0
        GROUP BY ii.`inventory_id`, ii.`item_id`, i.`max_quantity`
        HAVING COUNT(*) > i.`max_quantity`
        ORDER BY ii.`inventory_id`, ii.`item_id`;
    ]]))

    if TableExists('inventory_access') then
        AddRows(report, 'orphan_access_grant', 'error', MySQL.query.await([[
            SELECT ia.`id` AS `grantId`, ia.`inventory_id` AS `inventoryId`,
                   ia.`character_id` AS `characterId`
            FROM `inventory_access` ia LEFT JOIN `inventory` inv ON inv.`id`=ia.`inventory_id`
            WHERE inv.`id` IS NULL ORDER BY ia.`id`;
        ]]))
    end

    if TableExists('character_equipment') then
        AddRows(report, 'dangling_equipment', 'critical', MySQL.query.await([[
            SELECT ce.`character_id` AS `characterId`, ce.`slot`,
                   ce.`inventory_items_id` AS `instanceId`
            FROM `character_equipment` ce
            LEFT JOIN `inventory_items` ii ON ii.`id`=ce.`inventory_items_id`
            WHERE ii.`id` IS NULL ORDER BY ce.`character_id`, ce.`slot`;
        ]]))
        AddRows(report, 'equipment_owner_mismatch', 'critical', MySQL.query.await([[
            SELECT ce.`character_id` AS `equippedCharacterId`, ce.`slot`,
                   ce.`inventory_items_id` AS `instanceId`,
                   inv.`character_id` AS `inventoryCharacterId`, inv.`id` AS `inventoryId`
            FROM `character_equipment` ce
            INNER JOIN `inventory_items` ii ON ii.`id`=ce.`inventory_items_id`
            INNER JOIN `inventory` inv ON inv.`id`=ii.`inventory_id`
            WHERE inv.`character_id` IS NULL OR inv.`character_id`<>ce.`character_id`
            ORDER BY ce.`character_id`, ce.`slot`;
        ]]))
    end

    -- A lifecycle binding is considered missing only when the schema has the
    -- expected domain column and this row leaves it null. Unknown domains are
    -- not guessed at and therefore are not false-positively labelled orphaned.
    local columns = MySQL.query.await([[
        SELECT `COLUMN_NAME` FROM information_schema.COLUMNS
        WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='inventory';
    ]]) or {}
    local knownColumns = {}
    for _, column in ipairs(columns) do knownColumns[column.COLUMN_NAME] = true end
    for _, inventory in ipairs(MySQL.query.await('SELECT * FROM `inventory` ORDER BY `id`;') or {}) do
        local location = tostring(inventory.location or ''):lower()
        local ownerColumn = location == 'character' and 'character_id' or (location .. '_id')
        if location ~= '' and location ~= 'ground' and knownColumns[ownerColumn]
            and inventory[ownerColumn] == nil then
            report:add('unbound_container', 'error', {
                inventoryId = tonumber(inventory.id), location = location, ownerColumn = ownerColumn })
        end
    end

    report.ok = (report.summary.bySeverity.critical or 0) == 0
        and (report.summary.bySeverity.error or 0) == 0
    report.add = nil
    return Result.Ok(report)
end

function DiagnosticsAPI.RunIntegrityDiagnostics(options)
    local ok, result = pcall(RunIntegrityDiagnostics, options)
    if not ok then
        warn(('Integrity diagnostics failed: %s'):format(tostring(result)))
        return Result.Err(Result.Codes.INTERNAL, 'Integrity diagnostics could not complete.', {
            dryRun = true,
            cause = tostring(result),
        })
    end
    return result
end
