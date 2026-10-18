-- Alpha cutover implementation. No general enrollment export/command.
-- Dedicated Jane gate commits; the separate smoke command always rolls back.
CharacterAmmoEnrollment = {}
local E=CharacterAmmoEnrollment
local operation='alpha-character-ammo-enrollment-v1'
local function denied(message) return Result.Err(Result.Codes.CONFLICT,message) end
local function decode(value)
    if type(value)=='table' then return value end
    local ok,document=pcall(json.decode,value or '')
    return ok and document or nil
end
local function copy(value)
    if type(value)~='table' then return value end
    local result={}; for key,item in pairs(value) do result[key]=copy(item) end; return result
end
-- Narrow committed alpha gate, not general enrollment. No ammo is credited.
function E.ApplyJaneTest(tx,catalog,planner,limits)
    local characterId='6a2fd060-c46f-11f1-9ae2-e0d55eaa2deb'
    local headers=tx.query('SELECT id FROM inventory WHERE character_id = ? LIMIT 1 FOR UPDATE',{characterId})
    if not headers or not headers[1] then return denied('Test inventory missing.') end
    local rows=tx.query([[SELECT ii.id, ii.row_revision, ii.metadata, i.name, i.type
        FROM inventory_items ii INNER JOIN items i ON i.id=ii.item_id
        WHERE ii.inventory_id=? ORDER BY ii.id FOR UPDATE]],{tonumber(headers[1].id)})
    local row=type(rows)=='table' and #rows==1 and rows[1]
    if not row or tonumber(row.id)~=112 or tonumber(row.row_revision)~=0
        or row.name~='weapon_revolver_cattleman' or row.type~='item_weapon' then
        return denied('Exact one-item Jane baseline required: Cattleman112 revision0.')
    end
    local metadata=decode(row.metadata)
    local plan=planner.Build({{id=112,revision=0,name=row.name,type=row.type,metadata=metadata}},catalog,limits)
    if not plan.validationPassed or #plan.items~=1 or plan.items[1].selected~='ammo_revolver_regular' then
        return denied('Test weapon validation failed.')
    end
    for _,amount in pairs(plan.pools) do if amount~=0 then return denied('Zero ammunition baseline required.') end end
    local equipment=tx.query('SELECT slot FROM character_equipment WHERE character_id=? FOR UPDATE',{characterId})
    if type(equipment)~='table' or #equipment~=0 then return denied('Test character must have no equipped items.') end
    local enrolled=E.Apply(tx,characterId,catalog,planner,limits)
    if not enrolled.ok then return enrolled end
    if enrolled.value.items~=1 or enrolled.value.revision~=0 or enrolled.value.itemRevisions['112']~=1 then
        return denied('Unexpected test enrollment result.')
    end
    for _,amount in pairs(enrolled.value.pools) do if amount~=0 then return denied('Unexpected ammunition credit.') end end
    return enrolled
end
RegisterCommand('InvJaneAmmoEnroll',function(source,args)
    if source~=0 or Config.DevMode~=true then return end
    local prefix='[InvJaneAmmoEnroll] '
    local approved='6a2fd060-c46f-11f1-9ae2-e0d55eaa2deb'
    if Config.CharacterAmmunitionEnabled==true or GetResourceState('feather-weapons')~='stopped'
        or GetResourceState('feather-weapons-native-proof')~='stopped'
        or GuardsAPI.HasRegisteredGuard('feather-weapons') then
        print(prefix..'BLOCKED: native gate disabled, Weapons/proof stopped, retained guards cleared required'); return
    end
    local target=tonumber(args and args[1])
    if not target or target<1 or target%1~=0 or args[2]~=approved then
        print(prefix..'BLOCKED: explicit playerId and exact approved Jane UUID required'); return
    end
    local session=InventoryIdentity.GetSession(target)
    if not session or not session.ok or session.value.characterId~=approved then
        print(prefix..'BLOCKED: active target is not Jane'); return
    end
    local loaded,catalog,planner,limits=pcall(CharacterAmmoCutoverPreview.Load)
    if not loaded then print(prefix..'FAIL loading validated catalog'); return end
    local function current()
        return Config.CharacterAmmunitionEnabled~=true
            and GetResourceState('feather-weapons')=='stopped'
            and GetResourceState('feather-weapons-native-proof')=='stopped'
            and not GuardsAPI.HasRegisteredGuard('feather-weapons')
            and exports['feather-core']:IsSessionCurrent(target,session.value.sessionId,approved)==true
    end
    local result=TransactionAPI.Transaction({resource='feather-inventory',reason='dedicated_jane_ammo_enrollment'},function(tx)
        if not current() then return denied('Test context changed.') end
        local enrolled=E.ApplyJaneTest(tx,catalog,planner,limits)
        if not current() then return denied('Test context changed before commit.') end
        return enrolled
    end)
    if not result or not result.ok then
        print(prefix..'REFUSED '..tostring(result and result.error and result.error.message or 'transaction unavailable')); return
    end
    print(prefix..'COMMITTED characterId='..approved..' item112 revision1 ledgerRevision0 ammo0; no equip/native writes; production disabled')
end,true)
function E.Apply(tx,characterId,catalog,planner,limits)
    characterId=InventoryIdentity.NormalizeCharacterId(characterId)
    if not characterId then return denied('Valid character UUID required.') end
    local headers=tx.query('SELECT id FROM inventory WHERE character_id = ? LIMIT 1 FOR UPDATE',{characterId})
    if not headers or not headers[1] then return denied('Character inventory missing.') end
    local ledgers=tx.query('SELECT revision, pools FROM feather_character_ammunition WHERE character_id = ? FOR UPDATE',{characterId})
    local receipts=tx.query('SELECT result FROM feather_ammunition_operations WHERE character_id = ? AND operation_id = ? FOR UPDATE',{characterId,operation})
    -- Do not re-sum stripped item metadata. A later authenticated commit route
    -- must explicitly handle persisted receipts; this gate only tests fresh data.
    if #ledgers>0 or #receipts>0 then return denied('Character already enrolled or enrollment receipt exists.') end
    local rows=tx.query([[SELECT ii.id, ii.row_revision, ii.metadata, i.name, i.type
        FROM inventory_items ii INNER JOIN items i ON i.id=ii.item_id
        WHERE ii.inventory_id=? ORDER BY ii.id FOR UPDATE]],{tonumber(headers[1].id)})
    if type(rows)~='table' then return denied('Inventory snapshot unavailable.') end
    local items,documents={},{}
    for _,row in ipairs(rows) do
        local id=tonumber(row.id)
        local metadata=decode(row.metadata)
        items[#items+1]={id=id,name=row.name,type=row.type,revision=tonumber(row.row_revision),metadata=metadata}
        if id then documents[id]=metadata end
    end
    local plan=planner.Build(items,catalog,limits)
    if not plan.validationPassed then return denied('Enrollment validation failed: '..json.encode({issues=plan.issues,overflow=plan.overflow})) end
    for _,item in ipairs(plan.items) do
        if item.specialModePending then return denied('Special firearm mode is not gated yet.') end
    end
    local inserted=tx.query('INSERT INTO feather_character_ammunition (character_id, revision, pools) VALUES (?, 0, ?)',{characterId,json.encode(plan.pools)})
    if not inserted or tonumber(inserted.affectedRows)~=1 then return denied('Ledger insert failed.') end
    local revisions={}
    for _,item in ipairs(plan.items) do
        local document=copy(documents[item.itemId])
        -- Identity, serial, condition, attachments and cosmetics remain intact.
        -- Selected type is a preference only; no clip/reserve/pools authority.
        document.ammo={ownership='character',type=item.selected}
        local written=tx:SetMetadata(item.itemId,document,item.revision)
        if not Result.IsOk(written) then return written end
        if not written.value or written.value.revision~=item.revision+1 then return denied('Metadata revision did not advance exactly once.') end
        revisions[tostring(item.itemId)]=written.value.revision
    end
    local value={characterId=characterId,pools=plan.pools,revision=0,items=#plan.items,itemRevisions=revisions}
    local receipt=tx.query('INSERT INTO feather_ammunition_operations (character_id, operation_id, result) VALUES (?, ?, ?)',
        {characterId,operation,json.encode({fingerprint=operation,value=value})})
    if not receipt or tonumber(receipt.affectedRows)~=1 then return denied('Enrollment receipt insert failed.') end
    return Result.Ok(value)
end
-- Explicit console-only fresh empty-character initialization. No migration of
-- firearms/loose ammo, no implicit ledger creation in runtime snapshot readers.
function E.ApplyEmpty(tx,characterId,catalog,planner,limits,current)
    characterId=InventoryIdentity.NormalizeCharacterId(characterId)
    if not characterId or type(current)~='function' or current()~=true then return denied('Current empty enrollment authority required.') end
    local headers=tx.query('SELECT id FROM inventory WHERE character_id = ? LIMIT 1 FOR UPDATE',{characterId})
    if not headers or not headers[1] then return denied('Character inventory missing.') end
    local items=tx.query('SELECT id FROM inventory_items WHERE inventory_id=? FOR UPDATE',{tonumber(headers[1].id)})
    local equipment=tx.query('SELECT slot FROM character_equipment WHERE character_id=? FOR UPDATE',{characterId})
    if type(items)~='table' or next(items)~=nil or type(equipment)~='table' or next(equipment)~=nil then
        return denied('Empty inventory and equipment required; existing items need migration preview.')
    end
    if current()~=true then return denied('Enrollment authority changed.') end
    local result=E.Apply(tx,characterId,catalog,planner,limits)
    if not result.ok then return result end
    if result.value.items~=0 or result.value.revision~=0 then return denied('Unexpected empty enrollment result.') end
    for _,value in pairs(result.value.pools) do if value~=0 then return denied('Empty enrollment cannot credit ammunition.') end end
    if current()~=true then return denied('Enrollment authority changed before commit.') end
    return result
end
RegisterCommand('InvNativeEmptyAmmoEnroll',function(source,args)
    if source~=0 or Config.DevMode~=true then return end
    local prefix='[InvNativeEmptyAmmoEnroll] '
    local target=tonumber(args and args[1])
    local characterId=InventoryIdentity.NormalizeCharacterId(args and args[2])
    local function stopped()
        return Config.DevMode==true and GetResourceState('feather-weapons')=='stopped'
            and GetResourceState('feather-weapons-native-proof')=='stopped'
            and not GuardsAPI.HasRegisteredGuard('feather-weapons')
            and characterId~=nil and GetConvar('feather_native_empty_enrollment_character','')==characterId
    end
    if not target or target<1 or target%1~=0 or not stopped() then
        return print(prefix..'REFUSED explicit current target/UUID, exact opt-in, stopped Weapons/proof and cleared native guard required')
    end
    local session=InventoryIdentity.GetSession(target)
    if not session or not session.ok or session.value.characterId~=characterId then return print(prefix..'REFUSED current character mismatch') end
    local sessionId=session.value.sessionId
    local function current()
        return stopped() and exports['feather-core']:IsSessionCurrent(target,sessionId,characterId)==true
    end
    local loaded,catalog,planner,limits=pcall(CharacterAmmoCutoverPreview.Load)
    if not loaded or not current() then return print(prefix..'REFUSED policy/current authority unavailable') end
    local called,result=pcall(TransactionAPI.Transaction,{resource='feather-inventory',reason='explicit_empty_native_ammo_enrollment',
        actorSource=target,characterId=characterId,sessionId=sessionId},function(tx)
        return E.ApplyEmpty(tx,characterId,catalog,planner,limits,current)
    end)
    if called and result and result.ok then
        print(prefix..'COMMITTED '..json.encode(result.value)..'; no item/equipment/native/ammo grants')
    else print(prefix..'REFUSED '..tostring(called and result and result.error and result.error.message or 'transaction unconfirmed; inspect before retry')) end
end,true)
function E.ReadJaneBaseline(tx)
    local characterId='6a2fd060-c46f-11f1-9ae2-e0d55eaa2deb'
    local headers=tx.query('SELECT id FROM inventory WHERE character_id = ? LIMIT 1 FOR UPDATE',{characterId})
    if not headers or not headers[1] then return denied('Test inventory missing.') end
    local ledgers=tx.query('SELECT revision, pools FROM feather_character_ammunition WHERE character_id = ? FOR UPDATE',{characterId})
    local receipts=tx.query('SELECT result FROM feather_ammunition_operations WHERE character_id = ? AND operation_id = ? FOR UPDATE',{characterId,operation})
    local rows=tx.query([[SELECT ii.id, ii.row_revision, ii.metadata, i.name, i.type
        FROM inventory_items ii INNER JOIN items i ON i.id=ii.item_id
        WHERE ii.inventory_id=? ORDER BY ii.id FOR UPDATE]],{tonumber(headers[1].id)})
    local row=type(rows)=='table' and #rows==1 and rows[1]
    local ledger=ledgers and ledgers[1]
    local receipt=receipts and receipts[1] and decode(receipts[1].result)
    local function zero(document)
        if type(document)~='table' or document.ammo_revolver_regular~=0 then return false end
        for id in pairs(document) do if id~='ammo_revolver_regular' then return false end end
        return true
    end
    if not ledger or tonumber(ledger.revision)~=0 or not zero(decode(ledger.pools))
        or type(receipt)~='table' or receipt.fingerprint~=operation or type(receipt.value)~='table'
        or receipt.value.characterId~=characterId or receipt.value.revision~=0 or receipt.value.items~=1
        or not zero(receipt.value.pools) or type(receipt.value.itemRevisions)~='table'
        or receipt.value.itemRevisions['112']~=1 then return denied('Enrollment ledger/receipt baseline mismatch.') end
    if not row or tonumber(row.id)~=112 or tonumber(row.row_revision)~=1
        or row.name~='weapon_revolver_cattleman' or row.type~='item_weapon' then return denied('Enrolled item baseline mismatch.') end
    local metadata=decode(row.metadata)
    if type(metadata)~='table' or metadata.weaponDefinitionId~='revolver_cattleman'
        or type(metadata.serialNumber)~='string' or metadata.serialNumber==''
        or type(metadata.ammo)~='table' or metadata.ammo.ownership~='character'
        or metadata.ammo.type~='ammo_revolver_regular' then return denied('Enrolled metadata mismatch.') end
    for key in pairs(metadata.ammo) do
        if key~='ownership' and key~='type' then return denied('Item ammunition quantity forbidden.') end
    end
    return Result.Ok({characterId=characterId,itemId=112,itemRevision=1,ledgerRevision=0,
        ammo=0,serialNumber=metadata.serialNumber})
end
function E.ReadJaneEconomic(tx,limits,allowPrimary,roundtrip)
    local fundedEquipment=roundtrip=='funded-equipment'
    local orderlyStop=roundtrip=='orderly-stop' or fundedEquipment
    local previewRoundtrip=roundtrip=='preview-roundtrip' or orderlyStop
    local spent=roundtrip=='native-shot' or previewRoundtrip
    local nativeDeath=roundtrip=='native-death' or spent
    local nativeLogin=roundtrip=='native-login' or nativeDeath
    local drawRoundtrip=roundtrip=='native-draw' or nativeLogin
    local uiRoundtrip=roundtrip=='ui-roundtrip' or drawRoundtrip
    local automatic=roundtrip=='auto-login' or roundtrip=='auto-carried' or uiRoundtrip
    local login=roundtrip=='login' or automatic
    local carried=roundtrip=='carried' or roundtrip=='auto-carried'
    local expectedRevision=fundedEquipment and 25 or orderlyStop and 23 or previewRoundtrip and 21 or spent and 19 or nativeDeath and 17 or nativeLogin and 15 or drawRoundtrip and 13 or uiRoundtrip and 11 or automatic and (carried and 8 or 9) or login and 7 or carried and 6 or roundtrip and 5 or 3
    local operationCount=fundedEquipment and 24 or orderlyStop and 22 or previewRoundtrip and 20 or spent and 18 or expectedRevision
    local char='6a2fd060-c46f-11f1-9ae2-e0d55eaa2deb'
    local headers=tx.query('SELECT id FROM inventory WHERE character_id = ? LIMIT 1 FOR UPDATE',{char})
    if not headers or not headers[1] then return denied('Jane inventory missing.') end
    local ledger=tx.query('SELECT revision, pools FROM feather_character_ammunition WHERE character_id = ? FOR UPDATE',{char})
    local operations=tx.query('SELECT operation_id, result FROM feather_ammunition_operations WHERE character_id = ? ORDER BY operation_id FOR UPDATE',{char})
    local grants=tx.query([[SELECT request_fingerprint, result_json FROM inventory_grant_receipts
        WHERE source_resource=? AND grant_id=? FOR UPDATE]],{'feather-inventory','native-test-jane-revolver-regular-two-v1'})
    local rows=tx.query([[SELECT ii.id, ii.row_revision, ii.metadata, i.id AS definition_id, i.name, i.type
        FROM inventory_items ii INNER JOIN items i ON i.id=ii.item_id
        WHERE ii.inventory_id=? ORDER BY ii.id FOR UPDATE]],{tonumber(headers[1].id)})
    local equipment=tx.query('SELECT slot, inventory_items_id FROM character_equipment WHERE character_id=? FOR UPDATE',{char})
    local function poolsExact(value,regular)
        if type(value)~='table' or type(limits)~='table' then return false end
        local count=0
        for id in pairs(limits) do count=count+1; if value[id]~=(id=='ammo_revolver_regular' and regular or 0) then return false end end
        for id in pairs(value) do if limits[id]==nil then return false end end
        return count==27 and limits.ammo_revolver_regular~=nil
    end
    if not ledger or not ledger[1] or tonumber(ledger[1].revision)~=expectedRevision
        or not poolsExact(decode(ledger[1].pools),carried and 1 or 0) then return denied('Expected exact belt at revision'..expectedRevision..'.') end
    local equipped=type(equipment)=='table' and #equipment==1 and equipment[1].slot=='weapon'
        and tonumber(equipment[1].inventory_items_id)==112
    if type(equipment)~='table' or (#equipment~=0 and not (allowPrimary==true and equipped)) then
        return denied('Unexpected persisted equipment; empty or approved primary only.')
    end
    local firearm,ammo,ammoCount=nil,nil,0
    if type(rows)~='table' or #rows~=(previewRoundtrip and 3 or (carried or spent) and 1 or 2) then return denied('Unexpected firearm/loose round balance.') end
    for _,row in ipairs(rows) do
        if row.name=='weapon_revolver_cattleman' then firearm=row
        elseif row.name=='ammo_revolver_regular' and row.type=='item_ammo' then
            if ammo and tonumber(ammo.definition_id)~=tonumber(row.definition_id) then return denied('Loose ammo definition mismatch.') end
            ammo=row; ammoCount=ammoCount+1
        else return denied('Unexpected Jane inventory item.') end
    end
    if not firearm or (not carried and not spent and not ammo) or tonumber(firearm.id)~=112 or tonumber(firearm.row_revision)~=1
        or firearm.type~='item_weapon' then return denied('Exact item112 revision1 required.') end
    local metadata=decode(firearm.metadata)
    if type(metadata)~='table' or metadata.weaponDefinitionId~='revolver_cattleman'
        or metadata.serialNumber~='FW-REVO-6AC9DCDE-FDEBF3-0001' or type(metadata.ammo)~='table'
        or metadata.ammo.ownership~='character' or metadata.ammo.type~='ammo_revolver_regular' then return denied('Firearm metadata identity changed.') end
    for key in pairs(metadata.ammo) do if key~='ownership' and key~='type' then return denied('Item ammo quantity forbidden.') end end
    local grant=grants and grants[1] and decode(grants[1].result_json)
    local definition=tonumber((carried or spent) and grant and grant.definitionId or ammo and ammo.definition_id)
    if not definition or definition<1 or definition%1~=0 then return denied('Grant ammunition definition invalid.') end
    local fingerprint=table.concat({char,'ammo_revolver_regular',tostring(definition),'2'},'|')
    if not grant or grants[1].request_fingerprint~=fingerprint or grant.characterId~=char
        or grant.itemName~='ammo_revolver_regular' or grant.definitionId~=definition or grant.quantity~=2
        or grant.grantId~='native-test-jane-revolver-regular-two-v1' or type(grant.instanceIds)~='table'
        or grant.cancelled==true then return denied('Durable two-round grant receipt mismatch.') end
    if previewRoundtrip then
        local extraRows=tx.query([[SELECT request_fingerprint, result_json FROM inventory_grant_receipts
            WHERE source_resource=? AND grant_id=? FOR UPDATE]],{'feather-inventory','native-test-jane-preview-regular-two-v1'})
        local extra=extraRows and extraRows[1] and decode(extraRows[1].result_json)
        if ammoCount~=2 or not ammo or tonumber(ammo.definition_id)~=definition or not extra
            or extraRows[1].request_fingerprint~=fingerprint or extra.characterId~=char
            or extra.grantId~='native-test-jane-preview-regular-two-v1' or extra.itemName~='ammo_revolver_regular'
            or extra.definitionId~=definition or extra.quantity~=2 or type(extra.instanceIds)~='table'
            or extra.cancelled==true then return denied('Preview budget conservation mismatch.') end
    end
    local receipts={}
    for _,row in ipairs(operations or {}) do receipts[row.operation_id]=decode(row.result) end
    if type(operations)~='table' or #operations~=operationCount then return denied('Exact expected operation receipts required.') end
    local enrollment=receipts[operation]
    if not enrollment or enrollment.fingerprint~=operation or type(enrollment.value)~='table'
        or enrollment.value.characterId~=char or enrollment.value.revision~=0 or enrollment.value.items~=1
        or type(enrollment.value.itemRevisions)~='table' or enrollment.value.itemRevisions['112']~=1
        or type(enrollment.value.pools)~='table' or enrollment.value.pools.ammo_revolver_regular~=0 then return denied('Enrollment receipt changed.') end
    for id in pairs(enrollment.value.pools) do if id~='ammo_revolver_regular' then return denied('Enrollment receipt pools changed.') end end
    local expectedReceipts={{'jane-economic-load-v1','ammo_revolver_regular:2:0',1,-2,2},
        {'jane-economic-unload-v1','ammo_revolver_regular:-1:2',3,1,0}}
    if roundtrip then
        expectedReceipts[#expectedReceipts+1]={'jane-primary-load-v1','ammo_revolver_regular:1:3',4,-1,1}
        expectedReceipts[#expectedReceipts+1]={'jane-primary-unload-v1','ammo_revolver_regular:-1:4',5,1,0}
    end
    if login or carried then
        expectedReceipts[#expectedReceipts+1]={'jane-logout-load-v1','ammo_revolver_regular:1:5',6,-1,1}
    end
    if login then
        expectedReceipts[#expectedReceipts+1]={'jane-login-unload-v1','ammo_revolver_regular:-1:6',7,1,0}
    end
    if automatic then
        expectedReceipts[#expectedReceipts+1]={'jane-auto-login-load-v1','ammo_revolver_regular:1:7',8,-1,1}
        if not carried then
            expectedReceipts[#expectedReceipts+1]={'jane-auto-login-unload-v1','ammo_revolver_regular:-1:8',9,1,0}
        end
    end
    if uiRoundtrip then
        local found={}
        for id,receipt in pairs(receipts) do
            if type(id)=='string' and id:match('^ui:[%x%-]+:%d+:%d+$') then
                local value=receipt and receipt.value
                local revision=type(value)=='table' and value.revision
                if type(revision)~='number' or revision%1~=0 or revision<10 or revision>(previewRoundtrip and expectedRevision or operationCount)
                    or found[revision] then return denied('Unexpected UI receipt.') end
                found[revision]=id
            end
        end
        for revision=10,(spent and 17 or expectedRevision),2 do
            if not found[revision] or not found[revision+1] then
                return denied('Exact UI roundtrip receipts required.')
            end
            local sameSession=found[revision]:match('^ui:([^:]+):')==found[revision+1]:match('^ui:([^:]+):')
            -- The final loaded login crosses Core sessions; preceding UI
            -- roundtrips were deliberately performed within one session.
            if sameSession==(nativeLogin and revision==14) then return denied('UI receipt session boundary mismatch.') end
            expectedReceipts[#expectedReceipts+1]={found[revision],'ammo_revolver_regular:1:'..(revision-1),revision,-1,1}
            expectedReceipts[#expectedReceipts+1]={found[revision+1],'ammo_revolver_regular:-1:'..revision,revision+1,1,0}
        end
        if spent then
            if not found[18] then return denied('Final load receipt required.') end
            expectedReceipts[#expectedReceipts+1]={found[18],'ammo_revolver_regular:1:17',18,-1,1}
        end
        if previewRoundtrip then
            -- Observation19 has no economic receipt. The new grant supplies
            -- this subsequent conserved load/unload pair at20/21.
            local last=found[21]
            if not found[20] or not last or found[20]:match('^ui:([^:]+):')~=last:match('^ui:([^:]+):') then
                return denied('Preview roundtrip receipts required.')
            end
            expectedReceipts[#expectedReceipts+1]={found[20],'ammo_revolver_regular:1:19',20,-1,1}
            expectedReceipts[#expectedReceipts+1]={last,'ammo_revolver_regular:-1:20',21,1,0}
            if orderlyStop then
                if not found[22] or not found[23] or found[22]:match('^ui:([^:]+):')~=found[23]:match('^ui:([^:]+):') then
                    return denied('Orderly-stop same-session receipts required.')
                end
                expectedReceipts[#expectedReceipts+1]={found[22],'ammo_revolver_regular:1:21',22,-1,1}
                expectedReceipts[#expectedReceipts+1]={found[23],'ammo_revolver_regular:-1:22',23,1,0}
                if fundedEquipment then
                    if not found[24] or not found[25] or found[24]:match('^ui:([^:]+):')~=found[25]:match('^ui:([^:]+):') then
                        return denied('Funded-equipment same-session receipts required.')
                    end
                    expectedReceipts[#expectedReceipts+1]={found[24],'ammo_revolver_regular:1:23',24,-1,1}
                    expectedReceipts[#expectedReceipts+1]={found[25],'ammo_revolver_regular:-1:24',25,1,0}
                end
            end
        end
    end
    for _,expected in ipairs(expectedReceipts) do
        local receipt=receipts[expected[1]]; local value=receipt and receipt.value
        if not receipt or receipt.fingerprint~=expected[2] or type(value)~='table'
            or value.characterId~=char or value.operationId~=expected[1] or value.revision~=expected[3]
            or value.inventoryDelta~=expected[4] or not poolsExact(value.pools,expected[5]) then return denied('Economic receipt mismatch: '..expected[1]) end
    end
    return Result.Ok({characterId=char,ledgerRevision=expectedRevision,carried=carried and 1 or 0,loose=previewRoundtrip and 2 or (carried or spent) and 0 or 1,consumed=spent and 2 or 1,itemRevision=1,
        receipts=operationCount+(previewRoundtrip and 2 or 1),equipped=equipped==true})
end
-- Dedicated saved-primary gate. Never starts Weapons or materializes a native copy.
RegisterCommand('InvJanePrimary',function(source,args)
    if source~=0 or Config.DevMode~=true then return end
    local char='6a2fd060-c46f-11f1-9ae2-e0d55eaa2deb'
    local target=tonumber(args and args[1]); local mode=args and args[3]
    local fundedMode=mode=='verify-funded-equipment'
    if not target or target<1 or target%1~=0 or args[2]~=char or (not fundedMode and mode~='save' and mode~='verify' and mode~='verify-roundtrip' and mode~='verify-login' and mode~='verify-carried' and mode~='verify-auto-login' and mode~='verify-auto-carried' and mode~='verify-ui-roundtrip' and mode~='verify-native-draw' and mode~='verify-native-login' and mode~='verify-native-death' and mode~='verify-native-shot' and mode~='verify-preview-roundtrip' and mode~='verify-orderly-stop') then
        print('[InvJanePrimary] BLOCKED exact Jane UUID and save/verify/verify-roundtrip/verify-login required'); return
    end
    local session=InventoryIdentity.GetSession(target)
    if not session or not session.ok or session.value.characterId~=char then print('[InvJanePrimary] BLOCKED current Jane required'); return end
    local function current()
        return Config.DevMode==true and Config.CharacterAmmunitionEnabled~=true
            and (mode~='save' or GetConvar('feather_jane_primary','0')=='1')
            and GetResourceState('feather-weapons')=='stopped' and GetResourceState('feather-weapons-native-proof')=='stopped'
            and not GuardsAPI.HasRegisteredGuard('feather-weapons')
            and not GuardsAPI.HasRegisteredGuard('feather-weapons-jane-economic')
            and not GuardsAPI.HasRegisteredGuard('feather-weapons-jane-zero')
            and exports['feather-core']:IsSessionCurrent(target,session.value.sessionId,char)==true
    end
    local ok,result=pcall(function()
        assert(current(),'stopped/current opted-in context required')
        local catalog,_,_,_,_,policy=CharacterAmmoNativePreview.Load()
        local registry=assert(policy.Build(catalog))
        return TransactionAPI.Transaction({resource='feather-inventory',reason='jane_saved_primary_'..mode},function(tx)
            if not current() then return denied('Context changed.') end
            local read=E.ReadJaneEconomic(tx,registry.limits,true,fundedMode and 'funded-equipment' or mode=='verify-orderly-stop' and 'orderly-stop' or mode=='verify-preview-roundtrip' and 'preview-roundtrip' or mode=='verify-native-shot' and 'native-shot' or mode=='verify-native-death' and 'native-death' or mode=='verify-native-login' and 'native-login' or mode=='verify-native-draw' and 'native-draw' or mode=='verify-ui-roundtrip' and 'ui-roundtrip' or mode=='verify-auto-login' and 'auto-login' or mode=='verify-auto-carried' and 'auto-carried' or mode=='verify-carried' and 'carried' or mode=='verify-login' and 'login' or mode=='verify-roundtrip')
            if not read.ok then return read end
            if mode~='save' and not read.value.equipped then return denied('Saved primary missing.') end
            if mode=='save' and not read.value.equipped then
                -- Locked inventory/item/equipment rows above establish ownership and no conflicts.
                local conflicts=tx.query('SELECT character_id, slot FROM character_equipment WHERE inventory_items_id=? FOR UPDATE',{112})
                if type(conflicts)~='table' or #conflicts~=0 then return denied('Item112 already assigned elsewhere.') end
                local allowed,reason=GuardsAPI.CanChangeInstance(112,{operation='equipment_write'})
                if not allowed then return denied(reason or 'Equipment guard refused.') end
                if not current() then return denied('Context changed before write.') end
                tx.query('INSERT INTO character_equipment (character_id, slot, inventory_items_id) VALUES (?, ?, ?)',{char,'weapon',112})
                read=E.ReadJaneEconomic(tx,registry.limits,true)
                if not read.ok or not read.value.equipped then return denied('Saved primary readback mismatch.') end
            end
            if not current() then return denied('Context changed; transaction must roll back.') end
            return read
        end)
    end)
    if not ok or not result or not result.ok then
        print('[InvJanePrimary] FAIL '..tostring(ok and result and result.error and result.error.message or result)); return
    end
    print('[InvJanePrimary] PASS '..mode..' primary=weapon item112revision1 ledgerRevision'..result.value.ledgerRevision
        ..' carried'..result.value.carried..' loose'..result.value.loose..' receipts'..result.value.receipts..'; no native/ammo/metadata changes')
end,true)
RegisterCommand('InvJaneAmmoEconomicVerify',function(source,args)
    if source~=0 or Config.DevMode~=true then return end
    local char='6a2fd060-c46f-11f1-9ae2-e0d55eaa2deb'
    local target=tonumber(args and args[1])
    if not target or target<1 or target%1~=0 or args[2]~=char then print('[InvJaneAmmoEconomicVerify] BLOCKED exact Jane UUID required'); return end
    local session=InventoryIdentity.GetSession(target)
    if not session or not session.ok or session.value.characterId~=char then print('[InvJaneAmmoEconomicVerify] BLOCKED current Jane required'); return end
    local function current()
        return Config.CharacterAmmunitionEnabled~=true and GetResourceState('feather-weapons')=='stopped'
            and GetResourceState('feather-weapons-native-proof')=='stopped'
            and not GuardsAPI.HasRegisteredGuard('feather-weapons')
            and not GuardsAPI.HasRegisteredGuard('feather-weapons-jane-economic')
            and exports['feather-core']:IsSessionCurrent(target,session.value.sessionId,char)==true
    end
    local ok,result=pcall(function()
        assert(current(),'stopped/current test context required')
        local catalog,_,_,_,_,policy=CharacterAmmoNativePreview.Load()
        local registry=assert(policy.Build(catalog))
        return TransactionAPI.Transaction({resource='feather-inventory',reason='jane_economic_readback'},function(tx)
            if not current() then return denied('Context changed.') end
            local read=E.ReadJaneEconomic(tx,registry.limits)
            if not current() then return denied('Context changed during read.') end
            return read
        end)
    end)
    if not ok or not result or not result.ok then
        print('[InvJaneAmmoEconomicVerify] FAIL '..tostring(ok and result and result.error and result.error.message or result)); return
    end
    print('[InvJaneAmmoEconomicVerify] PASS revision3 carried0 loose1 consumed1 receipts4 item112revision1 unequipped; read-only durable conservation verified')
end,true)
RegisterCommand('InvJaneAmmoVerify',function(source,args)
    if source~=0 or Config.DevMode~=true then return end
    local prefix='[InvJaneAmmoVerify] '
    local approved='6a2fd060-c46f-11f1-9ae2-e0d55eaa2deb'
    local target=tonumber(args and args[1])
    if not target or target<1 or target%1~=0 or args[2]~=approved then
        print(prefix..'BLOCKED: explicit playerId and approved UUID required'); return
    end
    local session=InventoryIdentity.GetSession(target)
    if not session or not session.ok or session.value.characterId~=approved then
        print(prefix..'BLOCKED: active target is not Jane'); return
    end
    local function current()
        return Config.CharacterAmmunitionEnabled~=true
            and GetResourceState('feather-weapons')=='stopped'
            and GetResourceState('feather-weapons-native-proof')=='stopped'
            and not GuardsAPI.HasRegisteredGuard('feather-weapons')
            and exports['feather-core']:IsSessionCurrent(target,session.value.sessionId,approved)==true
    end
    local result=TransactionAPI.Transaction({resource='feather-inventory',reason='dedicated_jane_ammo_readback'},function(tx)
        if not current() then return denied('Test context changed.') end
        local read=E.ReadJaneBaseline(tx)
        if not current() then return denied('Test context changed during read.') end
        return read
    end)
    if not result or not result.ok then
        print(prefix..'REFUSED '..tostring(result and result.error and result.error.message or 'transaction unavailable')); return
    end
    print(prefix..'PASS characterId='..approved..' item112 revision1 ledgerRevision0 ammo0 receiptExact=true metadataExact=true serial='
        ..result.value.serialNumber..'; read-only; NOT production authorization')
end,true)
RegisterCommand('InvCharacterAmmoEnrollmentSmokeTest',function(source,args)
    if source~=0 or not Config.DevMode then return end
    local prefix='[InvCharacterAmmoEnrollmentSmokeTest] '
    if GetResourceState('feather-weapons')~='stopped' or GuardsAPI.HasRegisteredGuard('feather-weapons') then
        print(prefix..'BLOCKED: keep Weapons stopped; restart Inventory to clear retained Weapons guards'); return
    end
    local target=tonumber(args and args[1])
    local session=target and InventoryIdentity.GetSession(target)
    if not session or not session.ok then print(prefix..'BLOCKED: connected character required'); return end
    local characterId=session.value.characterId
    local withService=args and args[2]=='service'
    local withTransfer=withService and args[3]=='transfer'
    local withObservation=withService and args[3]=='observe'
    local looseBefore,ammoDefinition,inventoryId
    if withTransfer then
        inventoryId=InventoryControllers.GetInventoryByCharacter(characterId)
        ammoDefinition=ItemControllers.GetItemDefinitionByName('ammo_repeater_regular')
        if not inventoryId or not ammoDefinition then print(prefix..'BLOCKED: inventory/ammunition definition required'); return end
        looseBefore=InventoryControllers.InventoryItemCount(inventoryId,ammoDefinition.id)
        for _,id in ipairs({'rollback-service-load','rollback-service-unload'}) do
            if DB.one('SELECT character_id FROM feather_ammunition_operations WHERE character_id=? AND operation_id=?',characterId,id) then
                print(prefix..'BLOCKED: existing disposable operation receipt; preserving it'); return
            end
        end
    end
    if withService and GetResourceState('feather-weapons-native-proof')~='started' then
        print(prefix..'BLOCKED: updated native proof required for isolated service bridge'); return
    end
    local loaded,catalog,planner,limits=pcall(CharacterAmmoCutoverPreview.Load)
    if not loaded then print(prefix..'FAIL '..tostring(catalog)); return end
    local function current() return exports['feather-core']:IsSessionCurrent(target,session.value.sessionId,characterId)==true end
    local before,checks,value={}, {},nil
    local result=TransactionAPI.Transaction({resource='feather-inventory',reason='character_ammo_enrollment_rollback_smoke'},function(tx)
        if not current() then return denied('Session changed.') end
        -- E.Apply locks before validating/writing. Capture the exact input rows
        -- inside this transaction; compare unchanged bytes/revisions afterward.
        tx.query('SELECT id FROM inventory WHERE character_id = ? LIMIT 1 FOR UPDATE',{characterId})
        before=tx.query([[SELECT ii.id, ii.row_revision, ii.metadata FROM inventory_items ii
            INNER JOIN inventory inv ON inv.id=ii.inventory_id WHERE inv.character_id=? ORDER BY ii.id FOR UPDATE]],{characterId})
        local enrolled=E.Apply(tx,characterId,catalog,planner,limits)
        if not enrolled.ok then return enrolled end
        value=enrolled.value
        checks.enrollment=true
        local retry=E.Apply(tx,characterId,catalog,planner,limits)
        checks.duplicateRejected=not retry.ok
        local ledger=tx.query('SELECT revision, pools FROM feather_character_ammunition WHERE character_id = ? FOR UPDATE',{characterId})
        checks.ledgerExact=ledger[1] and tonumber(ledger[1].revision)==0
            and InventoryMetadata.DocumentsEqual(decode(ledger[1].pools),value.pools)
        local receipts=tx.query('SELECT result FROM feather_ammunition_operations WHERE character_id = ? AND operation_id = ? FOR UPDATE',{characterId,operation})
        local receipt=receipts[1] and decode(receipts[1].result)
        checks.ledgerExact=checks.ledgerExact and type(receipt)=='table' and receipt.fingerprint==operation
            and InventoryMetadata.DocumentsEqual(receipt.value,value)
        checks.metadataExact=true
        for _,row in ipairs(before) do
            local expected=value.itemRevisions[tostring(row.id)]
            if expected then
                local item=tx:GetItemForUpdate(tonumber(row.id))
                local original=copy(decode(row.metadata))
                original.ammo={ownership='character',type=original.ammo.type or catalog.weapons[original.weaponDefinitionId].ammunitionType}
                checks.metadataExact=checks.metadataExact and item.ok and item.value.revision==expected
                    and InventoryMetadata.DocumentsEqual(original,item.value.metadata)
            end
        end
        -- Validate actual stripped rows while they are still inside the rollback
        -- transaction. Unlike the read-only preview, do not simulate ownership.
        local nativeCatalog,nativeRegistryContract,nativeItemContract,materialization,leaseContract=CharacterAmmoNativePreview.Load()
        local nativePolicy={}
        for _,weapon in pairs(nativeCatalog.weapons) do
            if ({pistol=true,revolver=true,repeater=true,rifle=true,shotgun=true})[weapon.family]
                and weapon.nativeWeaponName~='WEAPON_REVOLVER_LEMAT' then
                for _,id in ipairs(weapon.ammunitionTypes) do nativePolicy[id]=limits[id] end
            end
        end
        local registry=assert(nativeRegistryContract.Build(nativeCatalog,nativePolicy))
        -- Exercise the same locked equipment reader used by the dormant
        -- production belt+loadout snapshot, not a separate preview query.
        local runtimeSnapshot=CharacterAmmunitionAPI.ReadSnapshot(tx,characterId,registry.limits,true)
        -- Production snapshots include zero entries for every approved type;
        -- enrollment credits only the types present in the input weapon data.
        local expectedPools=copy(value.pools)
        for id in pairs(registry.limits) do
            if expectedPools[id]==nil then expectedPools[id]=0 end
        end
        checks.runtimeSnapshotExact=runtimeSnapshot.ok and runtimeSnapshot.value.revision==value.revision
            and runtimeSnapshot.value.characterId==characterId
            and InventoryMetadata.DocumentsEqual(runtimeSnapshot.value.pools,expectedPools)
        local equipment=runtimeSnapshot.ok and Result.Ok(runtimeSnapshot.value.equipment) or runtimeSnapshot
        local nativePlan=equipment.ok and nativeItemContract.Loadout(equipment.value,nativeCatalog,registry)
        checks.nativeLoadoutExact=nativePlan~=nil
        if nativePlan then
            for _,item in pairs(nativePlan.slots) do
                checks.nativeLoadoutExact=checks.nativeLoadoutExact
                    and value.itemRevisions[tostring(item.itemInstanceId)]==item.itemRevision
                    and item.ammo==nil and item.loaded==nil
            end
        end
        checks.nativeLeaseBound=false
        if nativePlan then
            local creation=materialization.Build(equipment.value,nativeCatalog,registry,
                {characterId=characterId,sessionId=session.value.sessionId,epoch='rollback-loadout-lease'})
            if creation then
                local lease=leaseContract.New(creation)
                checks.nativeLeaseBound=lease.Validate({characterId=characterId,equipment=equipment.value},nativeCatalog,registry)==true
                local changed=copy(equipment.value)
                for _,item in pairs(changed) do
                    checks.nativeLeaseBound=checks.nativeLeaseBound and lease.Contains(item.id)
                    item.revision=item.revision+1
                end
                if next(changed) then
                    checks.nativeLeaseBound=checks.nativeLeaseBound
                        and not lease.Validate({characterId=characterId,equipment=changed},nativeCatalog,registry)
                end
            end
        end
        if not current() then return denied('Session changed before rollback.') end
        if withService then
            local changed=false
            local service
            local probeOpening,cancelOpening=true,false
            local ok
            ok,service=pcall(function()
                return exports['feather-weapons-native-proof']:CreateInventoryLoadoutFixture(
                    {source=target,sessionId=session.value.sessionId,characterId=characterId},
                    function(src,sid,char) return src==target and sid==session.value.sessionId and char==characterId and current() end,
                    function(caps)
                        if probeOpening then
                            probeOpening=false
                            local overlap=service.OpenLoadout(target,nativeCatalog,nativePolicy)
                            checks.serviceOpenOverlapVeto=type(overlap)=='table' and not overlap.ok
                                and overlap.error and overlap.error.code=='open_in_flight'
                        end
                        if cancelOpening then
                            cancelOpening=false
                            service.Revoke(target,session.value.sessionId)
                        end
                        local snapshot=CharacterAmmunitionAPI.ReadSnapshot(tx,characterId,caps,true)
                        if changed and snapshot.ok then
                            for _,item in pairs(snapshot.value.equipment) do item.revision=item.revision+1 end
                        end
                        return snapshot
                    end,nativeItemContract,withTransfer and function(context,spec)
                        checks.serviceEconomicTicketBound=context.actorSource==target and context.characterId==characterId
                            and context.sessionId==session.value.sessionId and type(context.runtimeTicket)=='string' and current()
                        if not checks.serviceEconomicTicketBound then return denied('Invalid bridge economic context.') end
                        return CharacterAmmunitionAPI.Apply(tx,context,spec)
                    end or nil,withObservation and function(context,spec)
                        checks.serviceObservationTicketBound=context.actorSource==target and context.characterId==characterId
                            and context.sessionId==session.value.sessionId and type(context.runtimeTicket)=='string' and current()
                        if not checks.serviceObservationTicketBound then return denied('Invalid bridge observation context.') end
                        return CharacterAmmunitionAPI.ApplyObservation(tx,context,spec)
                    end or nil)
            end)
            if not ok or type(service)~='table' then return denied('Service fixture unavailable: '..tostring(service)) end
            local opened=service.OpenLoadout(target,nativeCatalog,nativePolicy)
            checks.serviceOpenExact=opened.ok and opened.value.runtime.characterId==characterId
                and InventoryMetadata.DocumentsEqual(opened.value.runtime.pools,expectedPools)
                and #opened.value.creation.items==value.items
            if not checks.serviceOpenExact then return opened end
            local report=opened.value.runtime
            checks.serviceRestoreAck=service.ConfirmRestore(target,report).ok==true
            if withTransfer then
                local added=tx:AddQuantity(inventoryId,ammoDefinition.id,1)
                if not added.ok then service.Revoke(target); return added end
                local loaded=service.Transfer(target,report,'ammo_repeater_regular',1,'rollback-service-load')
                checks.serviceEconomicLoad=loaded.ok and loaded.value.phase=='restoring'
                    and loaded.value.revision==1 and loaded.value.pools.ammo_repeater_regular==expectedPools.ammo_repeater_regular+1
                    and tx:GetQuantity(inventoryId,ammoDefinition.id)==looseBefore
                if not checks.serviceEconomicLoad then service.Revoke(target); return loaded end
                checks.serviceEconomicBarrier=not service.Transfer(target,loaded.value,'ammo_repeater_regular',1,'too-soon').ok
                checks.serviceEconomicLoadAck=service.ConfirmRestore(target,loaded.value).ok==true
                local unloaded=service.Transfer(target,loaded.value,'ammo_repeater_regular',-1,'rollback-service-unload')
                checks.serviceEconomicUnload=unloaded.ok and unloaded.value.phase=='restoring' and unloaded.value.revision==2
                    and InventoryMetadata.DocumentsEqual(unloaded.value.pools,expectedPools)
                    and tx:GetQuantity(inventoryId,ammoDefinition.id)==looseBefore+1
                if not checks.serviceEconomicUnload then service.Revoke(target); return unloaded end
                checks.serviceEconomicUnloadAck=service.ConfirmRestore(target,unloaded.value).ok==true
                report=unloaded.value
            end
            if withObservation then
                local consumedType
                for id,count in pairs(report.pools) do if count>=2 then consumedType=id; break end end
                if not consumedType then service.Revoke(target); return denied('Observation bridge needs two carried rounds of one type.') end
                local initial=report.pools[consumedType]
                local shot=copy(report); shot.pools[consumedType]=initial-1
                local saved=service.Observe(target,shot)
                checks.serviceObservationDecrease=saved.ok and saved.value.revision==report.revision+1
                    and saved.value.pools[consumedType]==initial-1
                if not saved.ok then service.Revoke(target); return saved end
                local unchanged=service.Observe(target,saved.value)
                checks.serviceObservationUnchanged=unchanged.ok and unchanged.value.revision==saved.value.revision
                local increased=copy(saved.value); increased.pools[consumedType]=initial
                checks.serviceObservationIncreaseRejected=not service.Observe(target,increased).ok
                checks.serviceObservationStaleRejected=not service.Observe(target,shot).ok
                report=copy(saved.value); report.pools[consumedType]=initial-2
                local final=service.CheckpointAndSeal(target,report)
                checks.serviceObservationFinalReduction=final.ok and final.value.phase=='sealed'
                    and final.value.revision==saved.value.revision+1 and final.value.pools[consumedType]==initial-2
                if not final.ok then service.Revoke(target); return final end
                local actual=CharacterAmmunitionAPI.ReadSnapshot(tx,characterId,registry.limits,true)
                checks.serviceObservationLedgerExact=actual.ok and actual.value.revision==final.value.revision
                    and InventoryMetadata.DocumentsEqual(actual.value.pools,final.value.pools)
                report=final.value
            end
            local sealed=withObservation and {ok=true,value=report} or service.CheckpointAndSeal(target,report)
            checks.serviceSealRetains=sealed.ok
            for _,item in ipairs(opened.value.creation.items) do
                checks.serviceSealRetains=checks.serviceSealRetains and service.IsNativeItemBound(item.itemInstanceId)==true
            end
            if not sealed.ok then service.Revoke(target); return sealed end
            report=sealed.value; report.cleanupComplete=true; report.remainingCopies=0
            checks.serviceCleanupRelease=service.ConfirmCleanup(target,report).ok==true
            for _,item in ipairs(opened.value.creation.items) do
                checks.serviceCleanupRelease=checks.serviceCleanupRelease and not service.IsNativeItemBound(item.itemInstanceId)
            end
            opened=service.OpenLoadout(target,nativeCatalog,nativePolicy)
            if not opened.ok then return opened end
            report=opened.value.runtime
            if not service.ConfirmRestore(target,report).ok then service.Revoke(target); return denied('Fixture restore refused.') end
            changed=true
            local refused=service.Transfer(target,report,'ammo_repeater_regular',1,'fixture-stale-load')
            checks.serviceStaleTransferVeto=not refused.ok and refused.error.code~='persistence_failed'
            for _,item in ipairs(opened.value.creation.items) do
                checks.serviceStaleTransferVeto=checks.serviceStaleTransferVeto and service.IsNativeItemBound(item.itemInstanceId)==true
            end
            service.Revoke(target)
            changed=false; cancelOpening=true
            local cancelled=service.OpenLoadout(target,nativeCatalog,nativePolicy)
            checks.serviceCancelledOpenVeto=not cancelled.ok and cancelled.error
                and cancelled.error.code=='open_context_changed'
            for _,row in ipairs(before) do
                checks.serviceCancelledOpenVeto=checks.serviceCancelledOpenVeto
                    and not service.IsNativeItemBound(tonumber(row.id))
            end
        end
        return Result.Err(Result.Codes.DENIED,'intentional_enrollment_rollback')
    end)
    local after=DB.raw([[SELECT ii.id, ii.row_revision, ii.metadata FROM inventory_items ii
        INNER JOIN inventory inv ON inv.id=ii.inventory_id WHERE inv.character_id=? ORDER BY ii.id]],characterId)
    checks.rollback=result.ok==false and value~=nil and InventoryMetadata.DocumentsEqual(before,after)
        and not DB.one('SELECT character_id FROM feather_character_ammunition WHERE character_id=?',characterId)
        and not DB.one('SELECT character_id FROM feather_ammunition_operations WHERE character_id=? AND operation_id=?',characterId,operation)
    if withTransfer then
        checks.rollback=checks.rollback and InventoryControllers.InventoryItemCount(inventoryId,ammoDefinition.id)==looseBefore
        for _,id in ipairs({'rollback-service-load','rollback-service-unload'}) do
            checks.rollback=checks.rollback and not DB.one('SELECT character_id FROM feather_ammunition_operations WHERE character_id=? AND operation_id=?',characterId,id)
        end
    end
    local passed=0
    local names={'enrollment','duplicateRejected','ledgerExact','metadataExact','runtimeSnapshotExact','nativeLoadoutExact','nativeLeaseBound','rollback'}
    if withService then for _,name in ipairs({'serviceOpenExact','serviceRestoreAck','serviceSealRetains','serviceCleanupRelease','serviceStaleTransferVeto','serviceOpenOverlapVeto','serviceCancelledOpenVeto'}) do names[#names+1]=name end end
    if withTransfer then for _,name in ipairs({'serviceEconomicTicketBound','serviceEconomicLoad','serviceEconomicBarrier',
        'serviceEconomicLoadAck','serviceEconomicUnload','serviceEconomicUnloadAck'}) do names[#names+1]=name end end
    if withObservation then for _,name in ipairs({'serviceObservationTicketBound','serviceObservationDecrease','serviceObservationUnchanged',
        'serviceObservationIncreaseRejected','serviceObservationStaleRejected','serviceObservationFinalReduction',
        'serviceObservationLedgerExact'}) do names[#names+1]=name end end
    for _,name in ipairs(names) do
        if checks[name]==true then passed=passed+1 end
        print(prefix..name..' '..(checks[name]==true and 'PASS' or 'FAIL'))
    end
    print(prefix..('done %d/%d; rollback=%s; no native changes'):format(passed,#names,checks.rollback and 'VERIFIED' or 'NOT VERIFIED'))
    if value then print(prefix..'candidate '..json.encode(value)) else print(prefix..'failure '..json.encode(result)) end
end,true)
