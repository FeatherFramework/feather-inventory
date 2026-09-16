-- Generic ordinary-item fulfillment. No shop tables or payment decisions here.
GrantOnceAPI = {}
local function Invalid(message) return Result.Err('invalid_input', message) end
local function Validate(request, resource)
    if Config.TrustedIdempotentGrantCallers[resource or ''] ~= true then
        return Result.Err('authorization_denied', 'Idempotent grant caller is not trusted.')
    end
    if type(request) ~= 'table' then return Invalid('Grant request required.') end
    local characterId = InventoryIdentity.NormalizeCharacterId(request.characterId)
    if not characterId or type(request.grantId) ~= 'string' or #request.grantId > 128
        or not request.grantId:match('^[A-Za-z0-9][A-Za-z0-9._:%-]*$')
        or type(request.itemName) ~= 'string' or #request.itemName > 100
        or not request.itemName:match('^[a-z0-9_]+$')
        or type(request.quantity) ~= 'number' or request.quantity % 1 ~= 0
        or request.quantity < 1 or request.quantity > 100
        or type(request.definitionId) ~= 'number' or request.definitionId % 1 ~= 0
        or request.definitionId < 1 or request.definitionId > 9007199254740991 then
        return Invalid('Stable grant ID, Character UUID, definition ID, item name, and integer quantity required.')
    end
    for key in pairs(request) do
        if key ~= 'grantId' and key ~= 'characterId' and key ~= 'itemName'
            and key ~= 'quantity' and key ~= 'definitionId' then
            return Invalid('Unexpected grant request field.')
        end
    end
    return Result.Ok({ characterId = characterId,
        fingerprint = table.concat({ characterId, request.itemName,
            tostring(request.definitionId), tostring(request.quantity) }, '|') })
end
function GrantOnceAPI.Start()
    MySQL.query.await([[CREATE TABLE IF NOT EXISTS `inventory_grant_receipts` (
        `source_resource` VARCHAR(100) NOT NULL,
        `grant_id` VARCHAR(128) NOT NULL,
        `request_fingerprint` VARCHAR(300) NOT NULL,
        `result_json` LONGTEXT NULL,
        `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
        PRIMARY KEY (`source_resource`,`grant_id`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin]])
end
function GrantOnceAPI.Grant(request, resource)
    local validated = Validate(request, resource)
    if not validated.ok then return validated end
    -- Do not use the transaction runner's in-memory idempotency cache: this
    -- operation always reads the durable, payload-bound receipt while locked.
    return TransactionAPI.Transaction({ resource = resource,
        reason = 'idempotent_character_grant', correlationId = request.grantId }, function(tx)
        tx.query([[INSERT IGNORE INTO `inventory_grant_receipts`
            (`source_resource`,`grant_id`,`request_fingerprint`) VALUES (?,?,?)]],
            { resource, request.grantId, validated.value.fingerprint })
        local rows = tx.query([[SELECT `request_fingerprint`,`result_json`
            FROM `inventory_grant_receipts` WHERE `source_resource`=? AND `grant_id`=? FOR UPDATE]],
            { resource, request.grantId }) or {}
        local receipt = rows[1]
        if not receipt then return Result.Err('internal', 'Could not reserve grant receipt.') end
        if receipt.request_fingerprint ~= validated.value.fingerprint then
            return Result.Err('idempotency_conflict', 'Grant ID is bound to a different payload.')
        end
        if receipt.result_json then
            local decoded, result = pcall(json.decode, receipt.result_json)
            if not decoded or type(result) ~= 'table' then
                return Result.Err('internal', 'Stored grant receipt is invalid.')
            end
            if result.cancelled == true then
                return Result.Err('grant_cancelled', 'This grant was durably cancelled and cannot deliver.',
                    { grantId = request.grantId })
            end
            if type(result.instanceIds) ~= 'table' then
                return Result.Err('internal', 'Stored delivery receipt is incomplete.')
            end
            result.replayed = true
            return Result.Ok(result)
        end
        local definitions = tx.query([[SELECT `id`,`name`,`type`,`instance_mode`,`archived_at`
            FROM `items` WHERE `id`=? LIMIT 1 FOR UPDATE]], { request.definitionId }) or {}
        local definition = definitions[1]
        if not definition or definition.name ~= request.itemName or definition.archived_at ~= nil then
            return Result.Err('item_unavailable', 'Expected active item definition is unavailable.')
        end
        if definition.instance_mode ~= 'stack' or definition.type == 'weapon' then
            return Result.Err('unique_requires_issuer', 'Unique items require their owning issuer.')
        end
        local inventories = tx.query('SELECT `id` FROM `inventory` WHERE `character_id`=? LIMIT 1',
            { validated.value.characterId }) or {}
        if not inventories[1] then return Result.Err('not_found', 'Character inventory does not exist.') end
        local inventoryId = inventories[1].id
        local granted = tx:AddQuantity(inventoryId, definition.id, request.quantity)
        if not granted.ok then return granted end
        local result = { grantId = request.grantId, characterId = validated.value.characterId,
            inventoryId = inventoryId, definitionId = definition.id, itemName = definition.name,
            quantity = request.quantity, instanceIds = granted.value, replayed = false }
        tx.query([[UPDATE `inventory_grant_receipts` SET `result_json`=?
            WHERE `source_resource`=? AND `grant_id`=?]],
            { json.encode(result), resource, request.grantId })
        return Result.Ok(result)
    end)
end
-- Serialize cancellation against delivery on the SAME receipt row. A missing
-- receipt alone is never evidence for refund: cancellation must first commit
-- this terminal tombstone, preventing all later delivery attempts for the key.
function GrantOnceAPI.Cancel(request, resource)
    local validated = Validate(request, resource)
    if not validated.ok then return validated end
    return TransactionAPI.Transaction({ resource = resource,
        reason = 'cancel_character_grant', correlationId = request.grantId }, function(tx)
        tx.query([[INSERT IGNORE INTO `inventory_grant_receipts`
            (`source_resource`,`grant_id`,`request_fingerprint`) VALUES (?,?,?)]],
            { resource, request.grantId, validated.value.fingerprint })
        local rows = tx.query([[SELECT `request_fingerprint`,`result_json`
            FROM `inventory_grant_receipts` WHERE `source_resource`=? AND `grant_id`=? FOR UPDATE]],
            { resource, request.grantId }) or {}
        local receipt = rows[1]
        if not receipt then return Result.Err('internal', 'Could not reserve cancellation receipt.') end
        if receipt.request_fingerprint ~= validated.value.fingerprint then
            return Result.Err('idempotency_conflict', 'Grant ID is bound to a different payload.')
        end
        if receipt.result_json then
            local decoded, result = pcall(json.decode, receipt.result_json)
            if not decoded or type(result) ~= 'table' then
                return Result.Err('internal', 'Grant outcome is corrupt; cancellation is blocked.')
            end
            if result.cancelled == true and result.delivered == false then
                result.replayed = true
                return Result.Ok(result)
            end
            -- This is historical delivery evidence even if the units have since
            -- been consumed/moved/destroyed. Never infer no-delivery from count.
            return Result.Err('grant_already_delivered', 'Committed delivery blocks cancellation.',
                { grantId = request.grantId })
        end
        local result = { grantId = request.grantId, characterId = validated.value.characterId,
            definitionId = request.definitionId, itemName = request.itemName,
            quantity = request.quantity, cancelled = true, delivered = false, replayed = false }
        tx.query([[UPDATE `inventory_grant_receipts` SET `result_json`=?
            WHERE `source_resource`=? AND `grant_id`=?]],
            { json.encode(result), resource, request.grantId })
        return Result.Ok(result)
    end)
end
RegisterCommand('InventoryFulfillmentContractSmokeTest', function(source)
    if source ~= 0 then return end
    local base = { grantId = 'contract-test', characterId = '00000000-0000-4000-8000-000000000001',
        definitionId = 1, itemName = 'consumable_apple', quantity = 2 }
    local fractional = {}
    for key, value in pairs(base) do fractional[key] = value end
    fractional.quantity = 1.5
    local untrusted = Validate(base, 'untrusted-test-resource')
    local invalid = Validate({}, 'feather-shops')
    local tests = {
        { 'trusted caller configured', Config.TrustedIdempotentGrantCallers['feather-shops'] == true },
        { 'untrusted caller rejected', not untrusted.ok and untrusted.error.code == 'authorization_denied' },
        { 'incomplete request rejected', not invalid.ok and invalid.error.code == 'invalid_input' },
        { 'fractional quantity rejected', not Validate(fractional, 'feather-shops').ok },
        { 'complete request valid', Validate(base, 'feather-shops').ok },
        { 'receipts complete', tonumber(MySQL.scalar.await(
            'SELECT COUNT(*) FROM `inventory_grant_receipts` WHERE `result_json` IS NULL')) == 0 }
    }
    local passed = 0
    for _, test in ipairs(tests) do
        if test[2] then passed = passed + 1 end
        print(('[InventoryFulfillmentContractSmokeTest] %-28s %s'):format(test[1], test[2] and 'PASS' or 'FAIL'))
    end
    print(('[InventoryFulfillmentContractSmokeTest] done %d/%d passed (no items granted)'):format(passed, #tests))
end, true)
