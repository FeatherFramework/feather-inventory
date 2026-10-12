-- Data-only economic boundary: the transaction handle never leaves Inventory.
CharacterAmmunitionAPI = {}
local A = CharacterAmmunitionAPI
local function copy(value)
    if type(value)~='table' then return value end
    local result={}; for key,item in pairs(value) do result[key]=copy(item) end
    return result
end
local function err(code, message) return Result.Err(code, message) end
-- Narrow alpha gate; never substitutes for the Weapons runtime-ticket check.
local function janeEconomic(context,spec,operation)
    if Config.DevMode~=true or Config.CharacterAmmunitionEnabled==true
        or type(GetConvar)~='function' or GetConvar('feather_jane_ammo_economic','0')~='1'
        or type(context)~='table' or context.characterId~='6a2fd060-c46f-11f1-9ae2-e0d55eaa2deb'
        or type(spec)~='table' then return false end
    if operation=='transfer' then
        return spec.ammunitionId=='ammo_revolver_regular' and (
            (spec.amount==2 and spec.expectedRevision==0 and spec.operationId=='jane-economic-load-v1')
            or (spec.amount==-1 and spec.expectedRevision==2 and spec.operationId=='jane-economic-unload-v1')
            or (spec.amount==1 and spec.expectedRevision==3 and spec.operationId=='jane-primary-load-v1')
            or (spec.amount==-1 and spec.expectedRevision==4 and spec.operationId=='jane-primary-unload-v1')
            or (spec.amount==1 and spec.expectedRevision==5 and spec.operationId=='jane-logout-load-v1')
            or (spec.amount==-1 and spec.expectedRevision==6 and spec.operationId=='jane-login-unload-v1')
            or (spec.amount==1 and spec.expectedRevision==7 and spec.operationId=='jane-auto-login-load-v1')
            or (spec.amount==-1 and spec.expectedRevision==8 and spec.operationId=='jane-auto-login-unload-v1'))
    end
    if operation~='observe' or spec.expectedRevision~=1 or type(spec.pools)~='table'
        or type(spec.limits)~='table' then return false end
    local count=0
    for id in pairs(spec.limits) do
        count=count+1
        if spec.pools[id]~=(id=='ammo_revolver_regular' and 1 or 0) then return false end
    end
    for id in pairs(spec.pools) do if spec.limits[id]==nil then return false end end
    return count==27 and spec.limits.ammo_revolver_regular~=nil
end
local function integer(value)
    return type(value) == 'number' and value == value and value % 1 == 0
        and value >= 0 and value < math.huge
end
local function current(context)
    return type(context) == 'table' and tonumber(context.actorSource)
        and type(context.sessionId) == 'string'
        and exports['feather-core']:IsSessionCurrent(context.actorSource, context.sessionId, context.characterId) == true
end
local function pools(document, limits)
    if type(document) ~= 'table' or type(limits) ~= 'table' then return nil end
    local result = {}
    for id, amount in pairs(document) do
        if type(id) ~= 'string' or not integer(amount) or not integer(limits[id])
            or amount > limits[id] then return nil end
        result[id] = amount
    end
    for id, maximum in pairs(limits) do
        if type(id) ~= 'string' or not integer(maximum) or maximum > 10000 then return nil end
        result[id] = result[id] or 0
    end
    return result
end
-- Internal only; caller must own transaction and authenticate context. Exposed
-- export below never accepts a caller-supplied function or SQL.
function A.Apply(tx, context, spec)
    local characterId = InventoryIdentity.NormalizeCharacterId(context.characterId)
    if not characterId or type(spec) ~= 'table' or type(spec.operationId) ~= 'string'
        or #spec.operationId < 1 or #spec.operationId > 64
        or type(spec.ammunitionId) ~= 'string' or not spec.ammunitionId:match('^ammo_[a-z_]+$')
        or type(spec.amount) ~= 'number' or spec.amount == 0 or not integer(math.abs(spec.amount))
        or math.abs(spec.amount) > 1000 or not integer(spec.expectedRevision)
        or type(spec.limits) ~= 'table' then
        return err(Result.Codes.INVALID_INPUT, 'Invalid character ammunition transaction.')
    end
    -- Common order for all future shared-ammo routes: inventory header, ledger,
    -- receipts, item rows. The header serializes this character's economic work.
    local headers = tx.query('SELECT id FROM inventory WHERE character_id = ? LIMIT 1 FOR UPDATE', { characterId })
    local inventoryId = headers and headers[1] and tonumber(headers[1].id)
    if not inventoryId then return err(Result.Codes.NOT_FOUND, 'Character inventory missing.') end
    local denied = tx:RequireAccess(inventoryId,
        spec.amount > 0 and InventoryAPI.AccessModes.REMOVE or InventoryAPI.AccessModes.INSERT)
    if denied then return denied end
    local rows = tx.query('SELECT revision, pools FROM feather_character_ammunition WHERE character_id = ? FOR UPDATE', { characterId })
    local row = rows and rows[1]
    if not row then return err(Result.Codes.NOT_FOUND, 'Character ammunition is not enrolled.') end
    local fingerprint = table.concat({ spec.ammunitionId, tostring(spec.amount), tostring(spec.expectedRevision) }, ':')
    local receipts = tx.query('SELECT result FROM feather_ammunition_operations WHERE character_id = ? AND operation_id = ? FOR UPDATE',
        { characterId, spec.operationId })
    if receipts and receipts[1] then
        local ok, receipt = pcall(json.decode, receipts[1].result)
        if not ok or type(receipt) ~= 'table' or type(receipt.value) ~= 'table' or receipt.fingerprint ~= fingerprint then
            return err(Result.Codes.CONFLICT, 'Operation ID reused with different input or corrupt receipt.')
        end
        return Result.Ok(receipt.value)
    end
    local revision = tonumber(row.revision)
    if revision ~= spec.expectedRevision then return err(Result.Codes.CONFLICT, 'Ammunition revision changed.') end
    local ok, document = pcall(json.decode, row.pools)
    local accepted = ok and pools(document, spec.limits)
    if not accepted or accepted[spec.ammunitionId] == nil then
        return err(Result.Codes.CONFLICT, 'Invalid persisted ammunition or type.')
    end
    local after = accepted[spec.ammunitionId] + spec.amount
    if after < 0 or after > spec.limits[spec.ammunitionId] then
        return err(Result.Codes.LIMIT_EXCEEDED, 'Insufficient carried ammo or pool capacity exceeded.')
    end
    local definitions = tx.query('SELECT id, type, instance_mode, archived_at FROM items WHERE name = ? LIMIT 1', { spec.ammunitionId })
    local definition = definitions and definitions[1]
    if not definition or definition.type ~= 'item_ammo' or definition.instance_mode ~= 'stack'
        or definition.archived_at ~= nil then
        return err(Result.Codes.INVALID_INPUT, 'Active stack ammunition definition required.')
    end
    local changed
    if spec.amount > 0 then
        changed = tx:RemoveQuantity(inventoryId, tonumber(definition.id), spec.amount)
    else
        changed = tx:AddQuantity(inventoryId, tonumber(definition.id), -spec.amount)
    end
    if not Result.IsOk(changed) then return changed end
    accepted[spec.ammunitionId] = after
    local updated = tx.query('UPDATE feather_character_ammunition SET pools = ?, revision = ? WHERE character_id = ? AND revision = ?',
        { json.encode(accepted), revision + 1, characterId, revision })
    if not updated or tonumber(updated.affectedRows) ~= 1 then
        return err(Result.Codes.CONFLICT, 'Ammunition compare-and-set failed.')
    end
    local value = { characterId = characterId, pools = accepted, revision = revision + 1,
        operationId = spec.operationId, inventoryDelta = -spec.amount }
    local receiptWritten = tx.query('INSERT INTO feather_ammunition_operations (character_id, operation_id, result) VALUES (?, ?, ?)',
        { characterId, spec.operationId, json.encode({ fingerprint = fingerprint, value = value }) })
    if not receiptWritten or tonumber(receiptWritten.affectedRows) ~= 1 then
        return err(Result.Codes.CONFLICT, 'Ammunition receipt could not be persisted.')
    end
    return Result.Ok(value)
end
-- Reductions only: clip positions and weapon selection are never inputs here.
-- Weapons owns epoch/native-reset validation before calling this trusted route.
function A.ApplyObservation(tx,context,spec)
    local characterId=type(context)=='table' and InventoryIdentity.NormalizeCharacterId(context.characterId)
    if not characterId or type(spec)~='table' or not integer(spec.expectedRevision)
        or type(spec.limits)~='table' or type(spec.pools)~='table' or next(spec.limits)==nil then
        return err(Result.Codes.INVALID_INPUT,'Complete ammunition observation required.')
    end
    for id in pairs(spec.limits) do
        if spec.pools[id]==nil then return err(Result.Codes.INVALID_INPUT,'Incomplete ammunition observation.') end
    end
    local observed=pools(spec.pools,spec.limits)
    if not observed then return err(Result.Codes.INVALID_INPUT,'Invalid ammunition observation.') end
    local headers=tx.query('SELECT id FROM inventory WHERE character_id = ? LIMIT 1 FOR UPDATE',{characterId})
    if not headers or not headers[1] then return err(Result.Codes.NOT_FOUND,'Character inventory missing.') end
    local rows=tx.query('SELECT revision, pools FROM feather_character_ammunition WHERE character_id = ? FOR UPDATE',{characterId})
    local row=rows and rows[1]
    if not row then return err(Result.Codes.NOT_FOUND,'Character ammunition is not enrolled.') end
    local revision=tonumber(row.revision)
    if not integer(revision) or revision~=spec.expectedRevision then return err(Result.Codes.CONFLICT,'Ammunition revision changed.') end
    local decoded,document=pcall(json.decode,row.pools)
    local previous=decoded and pools(document,spec.limits)
    if not previous then return err(Result.Codes.CONFLICT,'Invalid persisted ammunition.') end
    local consumed,changed={},false
    for id,amount in pairs(observed) do
        if amount>previous[id] then return err(Result.Codes.CONFLICT,'Native ammunition pool increased.') end
        consumed[id]=previous[id]-amount
        changed=changed or consumed[id]>0
    end
    -- Idle samples must not generate revision churn or database writes.
    if changed then
        local updated=tx.query('UPDATE feather_character_ammunition SET pools = ?, revision = ? WHERE character_id = ? AND revision = ?',
            {json.encode(observed),revision+1,characterId,revision})
        if not updated or tonumber(updated.affectedRows)~=1 then return err(Result.Codes.CONFLICT,'Observation compare-and-set failed.') end
        revision=revision+1
    end
    return Result.Ok({characterId=characterId,pools=observed,revision=revision,consumed=consumed,changed=changed})
end
local function mutate(context,spec,invokingResource,apply,reason)
    local operation=apply==A.ApplyObservation and 'observe' or 'transfer'
    local function enabled(value)
        return Config.CharacterAmmunitionEnabled==true or janeEconomic(value,spec,operation)
    end
    if invokingResource ~= 'feather-weapons' or not enabled(context) then
        return err(Result.Codes.DENIED, 'Shared ammunition migration gate is disabled or caller is untrusted.')
    end
    -- Capture inputs before Core/runtime exports or SQL may yield. Authorization
    -- and persistence must see the same request, not mutable caller tables.
    context=copy(context); spec=copy(spec)
    if not current(context) then return err(Result.Codes.DENIED, 'Current character session required.') end
    local function runtimeCurrent(value)
        if not enabled(value) then return false end
        if type(value.runtimeEpoch)~='string' or type(value.runtimeTicket)~='string' then return false end
        local ok,allowed=pcall(function()
            return exports['feather-weapons']:ValidateCharacterAmmoRuntimeOperation(value,operation,spec)
        end)
        return ok and allowed==true
    end
    if not runtimeCurrent(context) then return err(Result.Codes.DENIED,'Current server ammunition operation required.') end
    -- Do NOT use generic in-memory idempotency: receipt lives in this commit.
    local safeContext = { actorSource = context.actorSource, characterId = context.characterId,
        actorCharacterId = context.characterId, sessionId = context.sessionId,
        resource = 'feather-weapons', reason = reason, correlationId = context.correlationId,
        runtimeEpoch=context.runtimeEpoch,runtimeTicket=context.runtimeTicket }
    return TransactionAPI.Transaction(safeContext, function(tx)
        if not current(safeContext) or not runtimeCurrent(safeContext) then return err(Result.Codes.DENIED, 'Session or runtime changed.') end
        local result = apply(tx, safeContext, spec)
        if not current(safeContext) or not runtimeCurrent(safeContext) then return err(Result.Codes.DENIED, 'Session or runtime changed before commit.') end
        return result
    end)
end
function A.Mutate(context,spec,invokingResource)
    return mutate(context,spec,invokingResource,A.Apply,'character_ammunition')
end
function A.Observe(context,spec,invokingResource)
    return mutate(context,spec,invokingResource,A.ApplyObservation,'character_ammunition_observation')
end
-- Read only, but still bound to the trusted current session. No automatic
-- enrollment, repair, schema creation or crediting loose inventory.
-- Called only inside the Inventory-owned snapshot transaction. These rows are
-- identity-bearing equipment data, never native handles or per-item ammo credit.
function A.ReadRuntimeEquipment(tx,characterId)
    local rows=tx.query([[SELECT ce.slot AS equipped_slot, ii.id, ii.row_revision,
        ii.metadata, i.name AS itemName, inv.character_id AS owner_character
        FROM character_equipment ce LEFT JOIN inventory_items ii ON ii.id=ce.inventory_items_id
        LEFT JOIN items i ON i.id=ii.item_id LEFT JOIN inventory inv ON inv.id=ii.inventory_id
        WHERE ce.character_id=? AND ce.slot IN ('weapon','weapon_offhand','weapon_shoulder','weapon_back')
        ORDER BY ii.id FOR UPDATE]],{characterId})
    if type(rows)~='table' then return err(Result.Codes.CONFLICT,'Equipment snapshot unavailable.') end
    local slots={weapon='primary',weapon_offhand='offhand',weapon_shoulder='shoulder',weapon_back='back'}
    local result,seen={},{}
    for _,row in ipairs(rows) do
        local slot=slots[row.equipped_slot]
        local id,revision=tonumber(row.id),tonumber(row.row_revision)
        local ok,metadata=pcall(function() return type(row.metadata)=='table' and row.metadata or json.decode(row.metadata) end)
        if not slot or result[slot] or not integer(id) or id==0 or seen[id] or not integer(revision)
            or row.owner_character~=characterId or type(row.itemName)~='string'
            or not ok or type(metadata)~='table' or type(metadata.ammo)~='table'
            or metadata.ammo.ownership~='character' or type(metadata.ammo.type)~='string' then
            return err(Result.Codes.CONFLICT,'Invalid enrolled equipment ownership or metadata.')
        end
        for key in pairs(metadata.ammo) do
            if key~='ownership' and key~='type' then return err(Result.Codes.CONFLICT,'Item ammunition quantity forbidden.') end
        end
        result[slot]={id=id,revision=revision,itemName=row.itemName,metadata=metadata}
        seen[id]=true
    end
    return Result.Ok(result)
end
-- Internal transaction reader, never exported. Caller owns the transaction and
-- session checks; this function grants nothing and never enrolls missing rows.
function A.ReadSnapshot(tx,characterId,limits,withEquipment)
    local headers=tx.query('SELECT id FROM inventory WHERE character_id = ? LIMIT 1 FOR UPDATE',{characterId})
    if not headers or not headers[1] then return err(Result.Codes.NOT_FOUND,'Character inventory missing.') end
    local rows=tx.query('SELECT revision, pools FROM feather_character_ammunition WHERE character_id = ? FOR UPDATE',{characterId})
    local row=rows and rows[1]
    if not row then return err(Result.Codes.NOT_FOUND,'Character ammunition is not enrolled.') end
    local decoded,document=pcall(json.decode,row.pools)
    local accepted=decoded and pools(document,limits)
    local revision=tonumber(row.revision)
    if not accepted or not integer(revision) then return err(Result.Codes.CONFLICT,'Invalid ammunition ledger.') end
    local equipment
    if withEquipment then
        local read=A.ReadRuntimeEquipment(tx,characterId)
        if not read.ok then return read end
        equipment=read.value
    end
    return Result.Ok({characterId=characterId,revision=revision,pools=accepted,equipment=equipment})
end
local function snapshot(context,limits,invokingResource,withEquipment)
    local function snapshotEnabled(value)
        if Config.CharacterAmmunitionEnabled==true then return true end
        -- Explicit server-only development read scope; never used by mutate.
        return Config.DevMode==true and type(GetConvar)=='function'
        and (GetConvar('feather_jane_ammo_readonly','0')=='1'
            or GetConvar('feather_jane_ammo_economic','0')=='1')
            and type(value)=='table' and value.characterId=='6a2fd060-c46f-11f1-9ae2-e0d55eaa2deb'
    end
    if invokingResource~='feather-weapons' or not snapshotEnabled(context) then
        return err(Result.Codes.DENIED,'Shared ammunition gate disabled or caller untrusted.')
    end
    context=copy(context); limits=copy(limits)
    if not current(context) or type(limits)~='table' or next(limits)==nil then
        return err(Result.Codes.DENIED,'Current session and server limits required.')
    end
    local safeContext={actorSource=context.actorSource,characterId=context.characterId,
        actorCharacterId=context.characterId,sessionId=context.sessionId,
        resource='feather-weapons',reason='character_ammunition_snapshot'}
    return TransactionAPI.Transaction(safeContext,function(tx)
        if not snapshotEnabled(safeContext) or not current(safeContext) then return err(Result.Codes.DENIED,'Gate or session changed.') end
        local result=A.ReadSnapshot(tx,safeContext.characterId,limits,withEquipment)
        if not result.ok then return result end
        if not snapshotEnabled(safeContext) or not current(safeContext) then return err(Result.Codes.DENIED,'Gate or session changed during snapshot.') end
        return result
    end)
end
function A.Snapshot(context,limits,invokingResource)
    return snapshot(context,limits,invokingResource,false)
end
function A.RuntimeSnapshot(context,limits,invokingResource)
    return snapshot(context,limits,invokingResource,true)
end

-- Console-only development gate. All character/item/receipt writes roll back.
-- Creating the two empty ledger tables is the only persistent schema effect.
RegisterCommand('InvCharacterAmmoTxSmokeTest', function(source, args)
    if source ~= 0 or not Config.DevMode then return end
    if GetResourceState('feather-weapons') == 'started' then
        print('[InvCharacterAmmoTxSmokeTest] BLOCKED: stop feather-weapons, then restart feather-inventory before testing')
        return
    end
    if GuardsAPI.HasRegisteredGuard('feather-weapons') then
        print('[InvCharacterAmmoTxSmokeTest] BLOCKED: retained feather-weapons guard; keep Weapons stopped and restart feather-inventory to clear registrations')
        return
    end
    local target = tonumber(args and args[1])
    local player = target and InventoryIdentity.GetCharacter(target)
    local id = player and player.char and InventoryIdentity.NormalizeCharacterId(player.char.id)
    if not id then print('[InvCharacterAmmoTxSmokeTest] connected target character required'); return end
    local inventoryId = InventoryControllers.GetInventoryByCharacter(id)
    local definition = ItemControllers.GetItemDefinitionByName('ammo_repeater_regular')
    if not inventoryId or not definition then print('[InvCharacterAmmoTxSmokeTest] inventory/ammo definition missing'); return end
    DB.exec([[CREATE TABLE IF NOT EXISTS feather_character_ammunition (
        character_id CHAR(36) NOT NULL PRIMARY KEY, revision BIGINT UNSIGNED NOT NULL DEFAULT 0,
        pools LONGTEXT NOT NULL, migrated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP) ENGINE=InnoDB]])
    DB.exec([[CREATE TABLE IF NOT EXISTS feather_ammunition_operations (
        character_id CHAR(36) NOT NULL, operation_id VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
        result LONGTEXT NOT NULL, created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
        PRIMARY KEY (character_id, operation_id)) ENGINE=InnoDB]])
    if DB.one('SELECT character_id FROM feather_character_ammunition WHERE character_id = ?', id) then
        print('[InvCharacterAmmoTxSmokeTest] refused: target already enrolled; use unmigrated test character'); return
    end
    local before = InventoryControllers.InventoryItemCount(inventoryId, definition.id)
    local withRuntime=args and args[2]=='runtime'
    local fixture,session
    if withRuntime then
        session=InventoryIdentity.GetSession(target)
        if not session or not session.ok or GetResourceState('feather-weapons-native-proof')~='started' then
            print('[InvCharacterAmmoTxSmokeTest] BLOCKED: active character and updated native proof required'); return
        end
        local ok,value=pcall(function() return exports['feather-weapons-native-proof']:CreateInventoryTransferFixture(function(src,sid,char)
            return src==target and sid==session.value.sessionId and char==id
                and exports['feather-core']:IsSessionCurrent(src,sid,char)==true
        end) end)
        if not ok or type(value)~='table' then print('[InvCharacterAmmoTxSmokeTest] BLOCKED: transfer fixture unavailable'); return end
        fixture=value
    end
    local checks, tested = {}, false
    local result = TransactionAPI.Transaction({ reason = 'character_ammo_rollback_smoke', resource = 'feather-inventory' }, function(tx)
        -- Trusted console fixture; real production export always requires session.
        tx.query('SELECT id FROM inventory WHERE id = ? FOR UPDATE', { inventoryId })
        local added = tx:AddQuantity(inventoryId, definition.id, 1)
        if not Result.IsOk(added) then return added end
        tx.query('INSERT INTO feather_character_ammunition (character_id, revision, pools) VALUES (?, 0, ?)',
            { id, json.encode({ ammo_repeater_regular = 2 }) })
        local context = { characterId = id }
        local spec = { operationId = 'rollback-proof-load', ammunitionId = 'ammo_repeater_regular',
            amount = 1, expectedRevision = 0, limits = { ammo_repeater_regular = 200 } }
        local request,transferContext
        local function prepare(amount,operationId)
            local state=fixture.client.Status().baseline
            local req=fixture.client.PrepareTransfer(1,state.pools,true,spec.ammunitionId,amount,operationId)
            if not req then return nil end
            local operation=fixture.runtime.PrepareTransfer(target,req.report,spec.ammunitionId,amount,operationId)
            transferContext=operation and operation.context
            return req,operation
        end
        if withRuntime then
            local opened=fixture.runtime.Open({source=target,characterId=id,sessionId=session.value.sessionId},
                {characterId=id,revision=0,pools={ammo_repeater_regular=2}},spec.limits,'rollback-transfer:'..session.value.sessionId)
            if not opened or not fixture.client.Begin(opened,spec.limits,1) then return err(Result.Codes.CONFLICT,'Transfer baseline rejected.') end
            local ack=fixture.client.Prepare(1,opened.pools,true)
            local restored=fixture.runtime.ConfirmRestore(target,ack.report)
            if not restored or not fixture.client.Accept(ack.id,Result.Ok(restored),1) then return err(Result.Codes.CONFLICT,'Initial restore refused.') end
            local txRequest
            request,txRequest=prepare(1,spec.operationId)
            if not request or not txRequest then return err(Result.Codes.CONFLICT,'Load ticket refused.') end
            checks.runtimeTicketBound=fixture.runtime.IsOperationCurrent(txRequest.context,'transfer',txRequest.spec)==true
        end
        local loaded = A.Apply(tx, context, spec)
        checks.load = loaded.ok == true and loaded.value.pools.ammo_repeater_regular == 3
        if not checks.load then return loaded end
        local function acknowledge(req,saved)
            return fixture.runtime.Complete(transferContext,saved)
        end
        local function restore(committed)
            local ack=fixture.client.Prepare(1,committed.pools,true)
            local accepted=ack and fixture.runtime.ConfirmRestore(target,ack.report)
            return accepted and fixture.client.Accept(ack.id,Result.Ok(accepted),1)
        end
        if withRuntime then
            local committed=acknowledge(request,loaded)
            local accepted=committed and fixture.client.Accept(request.id,Result.Ok(committed),1)
            checks.loadRestoreBarrier=accepted and accepted.phase=='restoring'
                and not fixture.client.PrepareTransfer(1,committed.pools,true,spec.ammunitionId,1,'too-soon')
            checks.duplicateReplyRejected=committed and not fixture.client.Accept(request.id,Result.Ok(committed),1)
            checks.loadRestoreAck=committed and restore(committed)~=nil
        end
        local retry = A.Apply(tx, context, spec)
        checks.retry = retry.ok == true and retry.value.revision == 1
            and tx:GetQuantity(inventoryId, definition.id) == before
        local mismatch = { operationId = spec.operationId, ammunitionId = spec.ammunitionId,
            amount = 2, expectedRevision = 0, limits = spec.limits }
        checks.reuseRejected = A.Apply(tx, context, mismatch).ok == false
        spec = { operationId = 'rollback-proof-unload', ammunitionId = spec.ammunitionId,
            amount = -1, expectedRevision = 1, limits = spec.limits }
        if withRuntime then
            local txRequest
            request,txRequest=prepare(-1,spec.operationId)
            if not request or not txRequest then return err(Result.Codes.CONFLICT,'Unload ticket refused.') end
        end
        local unloaded = A.Apply(tx, context, spec)
        checks.unload = unloaded.ok == true and unloaded.value.pools.ammo_repeater_regular == 2
            and tx:GetQuantity(inventoryId, definition.id) == before + 1
        if withRuntime and unloaded.ok then
            local committed=acknowledge(request,unloaded)
            checks.unloadRestoreAck=committed and fixture.client.Accept(request.id,Result.Ok(committed),1)~=nil
                and restore(committed)~=nil
        end
        tested = true
        return err(Result.Codes.DENIED, 'intentional_smoke_rollback')
    end)
    local after = InventoryControllers.InventoryItemCount(inventoryId, definition.id)
    checks.rollback = result.ok == false and before == after
        and not DB.one('SELECT character_id FROM feather_character_ammunition WHERE character_id = ?', id)
        and not DB.one('SELECT character_id FROM feather_ammunition_operations WHERE character_id = ? AND operation_id IN (?, ?)',
            id, 'rollback-proof-load', 'rollback-proof-unload')
    local passed = 0
    local names={ 'load', 'retry', 'reuseRejected', 'unload', 'rollback' }
    if withRuntime then for _,name in ipairs({'runtimeTicketBound','loadRestoreBarrier','duplicateReplyRejected',
        'loadRestoreAck','unloadRestoreAck'}) do names[#names+1]=name end end
    for _, name in ipairs(names) do
        local ok = checks[name] == true
        if ok then passed = passed + 1 end
        local status = ok and 'PASS' or (checks[name] == nil and 'NOT RUN' or 'FAIL')
        print(('[InvCharacterAmmoTxSmokeTest] %s %s'):format(name, status))
    end
    print(('[InvCharacterAmmoTxSmokeTest] done %d/%d; inventory before=%s after=%s; no native changes'):format(passed,#names, before, after))
    if not tested then print('[InvCharacterAmmoTxSmokeTest] failure ' .. json.encode(result)) end
end, true)
