-- Generic ordinary-item fulfillment. No shop tables or payment decisions here.
GrantOnceAPI = {}
-- Owning Weapons issuer only. This does not broaden ordinary-item grants.
NativeFirearmIssuanceAPI={}
function NativeFirearmIssuanceAPI.Apply(tx,context,spec,current)
    local function refused(message) return Result.Err('native_issuance_refused',message) end
    if current()~=true then return refused('Native issuance authority changed.') end
    local namespace='native-issue:'..spec.resource
    tx.query('INSERT IGNORE INTO inventory_grant_receipts (source_resource,grant_id,request_fingerprint) VALUES (?,?,?)',
        {namespace,spec.requestId,spec.fingerprint})
    local rows=tx.query('SELECT request_fingerprint,result_json FROM inventory_grant_receipts WHERE source_resource=? AND grant_id=? FOR UPDATE',
        {namespace,spec.requestId})
    local receipt=rows and rows[1]
    if not receipt or receipt.request_fingerprint~=spec.fingerprint or current()~=true then return refused('Issuance receipt conflict or authority changed.') end
    if receipt.result_json then
        local ok,value=pcall(json.decode,receipt.result_json)
        if not ok or type(value)~='table' or value.characterId~=context.characterId
            or value.definitionId~=spec.definitionId or value.itemName~=spec.itemName
            or type(value.revision)~='number' or value.revision<0 or value.revision%1~=0
            or type(value.itemInstanceId)~='number'
            or value.itemInstanceId<1 or value.itemInstanceId%1~=0 or type(value.metadata)~='table'
            or value.metadata.serialNumber~=value.serialNumber then return refused('Corrupt issuance receipt; no replacement granted.') end
        value.replayed=true
        return Result.Ok(value) -- historical result even after transfer/destruction
    end
    local headers=tx.query('SELECT id FROM inventory WHERE character_id=? LIMIT 1 FOR UPDATE',{context.characterId})
    local inventoryId=headers and headers[1] and tonumber(headers[1].id)
    if not inventoryId then return refused('Target inventory is unavailable.') end
    local ledgers=tx.query('SELECT revision FROM feather_character_ammunition WHERE character_id=? FOR UPDATE',{context.characterId})
    if not ledgers or not ledgers[1] then return refused('Target ammunition enrollment is required; no enrollment created.') end
    local definitions=tx.query('SELECT id,name,type,instance_mode FROM items WHERE name=? AND archived_at IS NULL FOR UPDATE',{spec.itemName})
    if not definitions or #definitions~=1 or definitions[1].type~='item_weapon' or definitions[1].instance_mode~='unique' then
        return refused('Expected active unique firearm definition is unavailable.')
    end
    if current()~=true then return refused('Native issuance authority changed.') end
    local created=tx:CreateInstance(inventoryId,tonumber(definitions[1].id),spec.metadata)
    if not created or not created.ok then return created or refused('Firearm creation failed.') end
    local value={itemInstanceId=created.value.instanceId,inventoryId=inventoryId,revision=created.value.revision,
        characterId=context.characterId,definitionId=spec.definitionId,itemName=spec.itemName,
        serialNumber=spec.metadata.serialNumber,metadata=spec.metadata,replayed=false}
    local updated=tx.query('UPDATE inventory_grant_receipts SET result_json=? WHERE source_resource=? AND grant_id=?',
        {json.encode(value),namespace,spec.requestId})
    if not updated or tonumber(updated.affectedRows or updated.affected_rows)~=1 or current()~=true then
        return refused('Issuance completion lost authority; transaction must roll back.')
    end
    return Result.Ok(value)
end
function NativeFirearmIssuanceAPI.Issue(context,spec,resource)
    if resource~='feather-weapons' or Config.CharacterAmmunitionEnabled~=true
        or type(context)~='table' or type(spec)~='table'
        or not InventoryIdentity.NormalizeCharacterId(context.characterId)
        or type(spec.resource)~='string' or #spec.resource<1 or #spec.resource>64
        or type(spec.requestId)~='string' or #spec.requestId>128 or not spec.requestId:match('^[A-Za-z0-9][A-Za-z0-9._:%-]*$')
        or type(spec.fingerprint)~='string' or #spec.fingerprint>300
        or type(spec.metadata)~='table' then return Result.Err('authorization_denied','Owning native issuer authority required.') end
    local function current()
        if Config.CharacterAmmunitionEnabled~=true then return false end
        local called,allowed=pcall(function() return exports['feather-weapons']:ValidateNativeIssuance(context,spec) end)
        return called and allowed==true
    end
    if not current() then return Result.Err('authorization_denied','Current native issuance ticket required.') end
    return TransactionAPI.Transaction({resource=resource,reason='native_firearm_issue',correlationId=spec.requestId},function(tx)
        return NativeFirearmIssuanceAPI.Apply(tx,context,spec,current)
    end)
end
local janeGrantKey={}
local janePreviewGrantKey={}
local throwableBudgetKey={}
local throwableDeathBudgetKey={}
local throwablePickupBudgetKey={}
local throwableBudgets={
    [throwableBudgetKey]={id='native-tomahawk-loose-budget-v1',quantity=2,
        convar='feather_native_throwable_budget',command='InvNativeThrowableBudget'},
    [throwableDeathBudgetKey]={id='native-tomahawk-death-budget-v1',quantity=1,
        convar='feather_native_throwable_death_budget',command='InvNativeThrowableDeathBudget'},
    [throwablePickupBudgetKey]={id='native-tomahawk-pickup-budget-v1',quantity=1,
        convar='feather_native_throwable_pickup_budget',command='InvNativeThrowablePickupBudget'},
}
local function throwableCallable(value)
    return type(value)=='function' or (type(value)=='table'
        and type(rawget(value,'__cfx_functionReference'))=='string')
end
local throwableBudgetCharacter='4560a489-ca6c-11f1-9ad4-e0d55eaa2deb'
local function throwableBudgetEnabled(key)
    local profile=throwableBudgets[key]
    return Config.DevMode==true and Config.CharacterAmmunitionEnabled==true
        and profile~=nil and type(GetConvar)=='function' and GetConvar(profile.convar,'0')=='1'
        and type(InventoryReadiness)=='table' and InventoryReadiness.state=='ready'
        and GetResourceState('feather-weapons-native-proof')=='stopped'
end
local jane='6a2fd060-c46f-11f1-9ae2-e0d55eaa2deb'
local janeGrantId='native-test-jane-revolver-regular-two-v1'
local janePreviewGrantId='native-test-jane-preview-regular-two-v1'
local function janeGrantEnabled(preview)
    return Config.DevMode==true and Config.CharacterAmmunitionEnabled~=true
        and type(InventoryReadiness)=='table' and InventoryReadiness.state=='ready'
        and type(GetConvar)=='function' and GetConvar(preview and 'feather_jane_preview_budget' or 'feather_jane_ammo_budget','0')=='1'
        and GetResourceState('feather-weapons')=='stopped'
        and GetResourceState('feather-weapons-native-proof')=='stopped'
end
local function Invalid(message) return Result.Err('invalid_input', message) end
local function Validate(request, resource, privateKey)
    local preview=privateKey==janePreviewGrantKey
    local dedicated=(privateKey==janeGrantKey or preview) and resource=='feather-inventory'
        and janeGrantEnabled(preview) and type(request)=='table' and request.characterId==jane
        and request.grantId==(preview and janePreviewGrantId or janeGrantId)
        and request.itemName=='ammo_revolver_regular' and request.quantity==2
    local budget=throwableBudgets[privateKey]
    local throwable=budget and resource=='feather-inventory' and throwableBudgetEnabled(privateKey)
        and type(request)=='table' and request.characterId==throwableBudgetCharacter
        and request.grantId==budget.id and request.itemName=='ammo_tomahawk_regular' and request.quantity==budget.quantity
    if Config.TrustedIdempotentGrantCallers[resource or ''] ~= true and not dedicated and not throwable then
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
    DB.exec([[CREATE TABLE IF NOT EXISTS `inventory_grant_receipts` (
        `source_resource` VARCHAR(100) NOT NULL,
        `grant_id` VARCHAR(128) NOT NULL,
        `request_fingerprint` VARCHAR(300) NOT NULL,
        `result_json` LONGTEXT NULL,
        `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
        PRIMARY KEY (`source_resource`,`grant_id`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin]])
end
function GrantOnceAPI.Grant(request, resource, privateKey, sessionCurrent)
    local validated = Validate(request, resource, privateKey)
    if not validated.ok then return validated end
    local function authorized()
        if throwableBudgets[privateKey] then
            return throwableBudgetEnabled(privateKey) and throwableCallable(sessionCurrent) and sessionCurrent()==true
        end
        if privateKey~=janeGrantKey and privateKey~=janePreviewGrantKey then return true end
        return janeGrantEnabled(privateKey==janePreviewGrantKey) and type(sessionCurrent)=='function' and sessionCurrent()==true
    end
    if not authorized() then return Result.Err('authorization_denied','Jane grant scope/session changed.') end
    -- Do not use the transaction runner's in-memory idempotency cache: this
    -- operation always reads the durable, payload-bound receipt while locked.
    return TransactionAPI.Transaction({ resource = resource,
        reason = 'idempotent_character_grant', correlationId = request.grantId }, function(tx)
        if not authorized() then return Result.Err('authorization_denied','Jane grant scope/session changed.') end
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
            if throwableBudgets[privateKey] and (result.characterId~=request.characterId
                or result.grantId~=request.grantId or result.definitionId~=request.definitionId
                or result.itemName~=request.itemName or result.quantity~=throwableBudgets[privateKey].quantity) then
                return Result.Err('internal','Stored throwable budget receipt does not match its fixed scope.')
            end
            result.replayed = true
            if not authorized() then return Result.Err('authorization_denied','Jane grant scope/session changed.') end
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
        if (privateKey==janeGrantKey or privateKey==janePreviewGrantKey or throwableBudgets[privateKey]) and definition.type~='item_ammo' then
            return Result.Err('item_unavailable','Regular revolver stack ammo required.')
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
        local saved=tx.query([[UPDATE `inventory_grant_receipts` SET `result_json`=?
            WHERE `source_resource`=? AND `grant_id`=?]],
            { json.encode(result), resource, request.grantId })
        if throwableBudgets[privateKey] and (not saved or tonumber(saved.affectedRows or saved.affected_rows)~=1) then
            return Result.Err('internal','Throwable budget receipt was not persisted; transaction must roll back.')
        end
        if not authorized() then return Result.Err('authorization_denied','Jane grant scope/session changed before commit.') end
        return Result.Ok(result)
    end)
end
local function JaneBudget(source,args,preview)
    if source~=0 then return end
    local target=tonumber(args and args[1])
    local prefix=preview and '[InvJanePreviewBudget]' or '[InvJaneAmmoBudget]'
    if not janeGrantEnabled(preview) or not target or target<1 or target%1~=0 or args[2]~=jane then
        print(prefix..' BLOCKED: exact Jane UUID, opt-in, disabled production and stopped Weapons/proof required'); return
    end
    local called,result=pcall(function()
        local session=exports['feather-core']:GetSessionContext(target)
        assert(session and session.ok and session.value.characterId==jane,'Jane session required')
        local function current()
            return exports['feather-core']:IsSessionCurrent(target,session.value.sessionId,jane)==true
        end
        assert(current(),'current Jane required')
        local definition=ItemControllers.GetItemDefinitionByName('ammo_revolver_regular')
        assert(definition and definition.type=='item_ammo' and definition.instance_mode=='stack','ammo definition required')
        return GrantOnceAPI.Grant({characterId=jane,grantId=preview and janePreviewGrantId or janeGrantId,
            definitionId=tonumber(definition.id),itemName='ammo_revolver_regular',quantity=2},
            'feather-inventory',preview and janePreviewGrantKey or janeGrantKey,current)
    end)
    if not called or not result or not result.ok then
        print(prefix..' FAIL '..tostring(called and result and result.error and result.error.code or result)); return
    end
    print(prefix..' PASS quantity=2 ammo_revolver_regular replayed='..tostring(result.value.replayed==true)
        ..' characterId='..jane..'; durable loose-ammo grant only; no carried/native/equip changes')
end
RegisterCommand('InvJaneAmmoBudget',function(source,args) JaneBudget(source,args,false) end,true)
RegisterCommand('InvJanePreviewBudget',function(source,args) JaneBudget(source,args,true) end,true)
-- Fixed development allowance, loose stacks only. Receipt replay never tops up
-- spent/transferred quantities; it cannot enroll or change carried/native ammo.
local function throwableBudgetCommand(source,args,key)
    if source~=0 then return end
    local profile=throwableBudgets[key]
    local prefix='['..profile.command..']'
    local target=tonumber(args and args[1])
    if not throwableBudgetEnabled(key) or not target or target<1 or target%1~=0
        or not args or #args~=2 or args[2]~=throwableBudgetCharacter then
        return print(prefix..' REFUSED exact John/current source and explicit budget gate required')
    end
    local ok,result=pcall(function()
        local session=exports['feather-core']:GetSessionContext(target)
        assert(session and session.ok and session.value.characterId==throwableBudgetCharacter,'John session required')
        local function current()
            return exports['feather-core']:IsSessionCurrent(target,session.value.sessionId,throwableBudgetCharacter)==true
        end
        assert(current(),'current John required')
        local definition=ItemControllers.GetItemDefinitionByName('ammo_tomahawk_regular')
        assert(definition and definition.type=='item_ammo' and definition.instance_mode=='stack','regular Tomahawk stack definition required')
        return GrantOnceAPI.Grant({characterId=throwableBudgetCharacter,grantId=profile.id,
            itemName='ammo_tomahawk_regular',definitionId=tonumber(definition.id),quantity=profile.quantity},
            'feather-inventory',key,current)
    end)
    print(prefix..' '..(ok and result and result.ok and 'PASS ' or 'REFUSED ')
        ..(ok and json.encode(result) or tostring(result))..'; loose stack only; no carried/native/equipment writes')
end
RegisterCommand('InvNativeThrowableBudget',function(source,args) throwableBudgetCommand(source,args,throwableBudgetKey) end,true)
RegisterCommand('InvNativeThrowableDeathBudget',function(source,args) throwableBudgetCommand(source,args,throwableDeathBudgetKey) end,true)
RegisterCommand('InvNativeThrowablePickupBudget',function(source,args) throwableBudgetCommand(source,args,throwablePickupBudgetKey) end,true)
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
        { 'receipts complete', tonumber(DB.value(
            'SELECT COUNT(*) FROM `inventory_grant_receipts` WHERE `result_json` IS NULL')) == 0 }
    }
    local passed = 0
    for _, test in ipairs(tests) do
        if test[2] then passed = passed + 1 end
        print(('[InventoryFulfillmentContractSmokeTest] %-28s %s'):format(test[1], test[2] and 'PASS' or 'FAIL'))
    end
    print(('[InventoryFulfillmentContractSmokeTest] done %d/%d passed (no items granted)'):format(passed, #tests))
end, true)
