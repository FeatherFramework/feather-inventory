-- One disposable alpha fixture, not a general grant API. A database rebuild
-- resets this receipt; retained audit files from that database must be discarded.
NativeRepairFixture={}
local jane='6a2fd060-c46f-11f1-9ae2-e0d55eaa2deb'
local grant='native-test-jane-repair-fixture-v1'
local fingerprint=jane..'|repair-cattleman-oil|1|v1'
local function copy(v)
    if type(v)~='table' then return v end
    local out={}; for k,x in pairs(v) do out[k]=copy(x) end; return out
end
local function denied(message) return Result.Err('repair_fixture_refused',message) end
function NativeRepairFixture.Apply(tx,current,limits,itemContract,definition)
    if current()~=true then return denied('Current opted-in alpha fixture required.') end
    tx.query([[INSERT IGNORE INTO inventory_grant_receipts (source_resource,grant_id,request_fingerprint)
        VALUES (?,?,?)]],{'feather-inventory',grant,fingerprint})
    local receipts=tx.query([[SELECT request_fingerprint,result_json FROM inventory_grant_receipts
        WHERE source_resource=? AND grant_id=? FOR UPDATE]],{'feather-inventory',grant})
    local receipt=receipts and receipts[1]
    if current()~=true or not receipt or receipt.request_fingerprint~=fingerprint then return denied('Fixture receipt unavailable/conflicting.') end
    if receipt.result_json then
        local called,value=pcall(json.decode,receipt.result_json)
        if not called or type(value)~='table' or value.characterId~=jane or type(value.fixtureId)~='number'
            or value.fixtureId==112 or type(value.oilId)~='number' then return denied('Corrupt fixture receipt.') end
        value.replayed=true; return Result.Ok(value) -- historical receipt; never recreate consumed units
    end
    local baseline=CharacterAmmoEnrollment.ReadJaneEconomic(tx,limits,true,'funded-equipment')
    if not baseline.ok then return baseline end
    local headers=tx.query('SELECT id FROM inventory WHERE character_id=? LIMIT 1 FOR UPDATE',{jane})
    local inventoryId=headers and headers[1] and tonumber(headers[1].id)
    local original=tx:GetItemForUpdate(112)
    if current()~=true or not inventoryId or not original.ok or original.value.inventoryId~=inventoryId
        or original.value.revision~=1 or original.value.definition.name~='weapon_revolver_cattleman' then
        return denied('Original accepted primary required; no changes permitted.')
    end
    local oil=tx.query('SELECT id FROM items WHERE name=? AND archived_at IS NULL LIMIT 1',{'gun_oil'})
    local oilDefinition=oil and oil[1] and tonumber(oil[1].id)
    if current()~=true or not oilDefinition then return denied('Gun oil definition missing.') end
    local metadata=copy(original.value.metadata)
    metadata.serialNumber='FW-ALPHA-REPAIR-JANE-V1'
    metadata.condition=50
    metadata.maintenance={degradation=0.5,permanentDegradation=0.1,damage=0.5,dirt=0.7,soot=0.3}
    metadata.provenance={alphaRepairFixture=true}
    local valid=itemContract.Validate(metadata,definition)
    if not valid then return denied('Fixture metadata invalid.') end
    local created=tx:CreateInstance(inventoryId,original.value.definition.id,metadata)
    if current()~=true then return denied('Fixture context changed during creation.') end
    if not created.ok then return created end
    local added=tx:AddQuantity(inventoryId,oilDefinition,1,{})
    if current()~=true then return denied('Fixture context changed during material grant.') end
    if not added.ok then return added end
    local value={characterId=jane,fixtureId=created.value.instanceId,fixtureRevision=created.value.revision,
        oilId=added.value[1],condition=50,repairCeiling=90,replayed=false,originalItemId=112}
    if value.fixtureId==112 or not value.oilId then return denied('Invalid created fixture identity.') end
    local updated=tx.query([[UPDATE inventory_grant_receipts SET result_json=?
        WHERE source_resource=? AND grant_id=?]],{json.encode(value),'feather-inventory',grant})
    if current()~=true or not updated or tonumber(updated.affectedRows or updated.affected_rows)~=1 then
        return denied('Fixture receipt completion failed.')
    end
    return Result.Ok(value)
end
RegisterCommand('InvJaneRepairFixture',function(source,args)
    if source~=0 then return end
    local target=tonumber(args and args[1])
    if not args or #args~=2 or args[2]~=jane or not target or target<1 or target%1~=0 or target==math.huge then
        return print('[InvJaneRepairFixture] usage: current-server-id '..jane)
    end
    local session=InventoryIdentity.GetSession(target)
    local function current()
        return Config.DevMode==true and Config.CharacterAmmunitionEnabled~=true
            and InventoryReadiness.state=='ready' and GetConvar('feather_jane_repair_fixture','0')=='1'
            and GetResourceState('feather-weapons')=='stopped' and GetResourceState('feather-weapons-native-proof')=='stopped'
            and session and session.ok and session.value.characterId==jane
            and exports['feather-core']:IsSessionCurrent(target,session.value.sessionId,jane)==true
    end
    local called,result=pcall(function()
        if not current() then return denied('Stopped/current opted-in fixture context required.') end
        local catalog,_,itemContract,_,_,policy=CharacterAmmoNativePreview.Load()
        local registry=assert(policy.Build(catalog))
        return TransactionAPI.Transaction({resource='feather-inventory',reason='native_repair_fixture'},function(tx)
            return NativeRepairFixture.Apply(tx,current,registry.limits,itemContract,catalog.weapons.revolver_cattleman)
        end)
    end)
    if called and result and result.ok then print('[InvJaneRepairFixture] PASS '..json.encode(result.value)..'; one disposable worn firearm/one oil, no equipment/ammo changes')
    else print('[InvJaneRepairFixture] REFUSED '..tostring(called and result and result.error and result.error.message or result)) end
end,true)

-- Disposable existing Carbine only. This is explicit alpha fixture metadata,
-- NOT attachment payment, a general item editor, or a grant operation.
NativeSavedAttachmentFixture={}
function NativeSavedAttachmentFixture.Apply(tx,current,mode,itemContract,definition)
    local function refuse(message) return Result.Err('saved_attachment_fixture_refused',message) end
    if current()~=true or (mode~='install' and mode~='remove') then return refuse('Stopped scoped fixture required.') end
    local headers=tx.query('SELECT id FROM inventory WHERE character_id=? LIMIT 1 FOR UPDATE',{jane})
    local inventoryId=headers and headers[1] and tonumber(headers[1].id)
    local equipment=tx.query('SELECT slot, inventory_items_id FROM character_equipment WHERE character_id=? ORDER BY slot FOR UPDATE',{jane})
    if not inventoryId or type(equipment)~='table' then return refuse('Fixture inventory/equipment unavailable.') end
    for _,row in ipairs(equipment) do
        if tonumber(row.inventory_items_id)==135 then return refuse('Unequip disposable Carbine135 before stopping Weapons.') end
    end
    local locked=tx:GetItemForUpdate(135)
    local item=locked and locked.ok and locked.value
    if not item or item.inventoryId~=inventoryId or not item.definition or item.definition.name~='weapon_repeater_carbine'
        or type(item.metadata)~='table' or item.metadata.serialNumber~='FW-ALPHA-MIXED-JANE-V1-repeater_carbine'
        or item.metadata.weaponDefinitionId~='repeater_carbine' or item.metadata.condition~=100
        or type(item.metadata.maintenance)~='table' then return refuse('Exact pristine disposable Carbine135 required.') end
    for _,field in ipairs({'damage','degradation','permanentDegradation','dirt','soot'}) do
        if item.metadata.maintenance[field]~=0 then return refuse('Pristine fixture maintenance required.') end
    end
    if not itemContract.Validate(item.metadata,definition) then return refuse('Canonical firearm metadata required.') end
    local attachments=item.metadata.attachments
    local empty=type(attachments)=='table' and next(attachments)==nil
    local installed=type(attachments)=='table' and type(attachments[1])=='table'
        and attachments[1].definitionId=='carbine_wide_sight' and attachments[1].slot=='sight'
    if installed then
        for key in pairs(attachments) do if key~=1 then installed=false end end
        for key in pairs(attachments[1]) do if key~='definitionId' and key~='slot' then installed=false end end
    end
    if current()~=true then return refuse('Fixture session changed.') end
    if (mode=='install' and installed and item.revision==1) or (mode=='remove' and empty and item.revision==2) then
        return Result.Ok({itemId=135,revision=item.revision,mode=mode,unchanged=true,noAmmoOrMaterialWrites=true})
    end
    if not ((mode=='install' and empty and item.revision==0) or (mode=='remove' and installed and item.revision==1)) then
        return refuse('Fixture expected revision0 install/revision1 remove only; never overwrite unknown state.')
    end
    local metadata=copy(item.metadata)
    metadata.attachments=mode=='install' and {{definitionId='carbine_wide_sight',slot='sight'}} or {}
    if not itemContract.Validate(metadata,definition) then return refuse('Projected metadata invalid.') end
    local expectedRevision=item.revision
    local result=tx:SetMetadata(135,metadata,expectedRevision)
    if current()~=true then return refuse('Fixture scope changed during write; rollback required.') end
    if not result or not result.ok then return result or refuse('Fixture CAS failed.') end
    return Result.Ok({itemId=135,revision=expectedRevision+1,mode=mode,unchanged=false,
        fixtureMetadataWrite=true,noAmmoOrMaterialWrites=true,noEquipmentWrites=true})
end
RegisterCommand('InvJaneSavedAttachmentFixture',function(source,args)
    if source~=0 then return end
    local target=tonumber(args and args[1])
    local mode=args and args[3]
    if not args or #args~=3 or args[2]~=jane or not target or target<1 or target%1~=0 or target==math.huge
        or (mode~='install' and mode~='remove' and mode~='inspect') then
        return print('[InvJaneSavedAttachmentFixture] usage: current-server-id '..jane..' install|remove|inspect')
    end
    local readSession,session=pcall(InventoryIdentity.GetSession,target)
    if not readSession then session=nil end
    local function gates()
        local value=session and session.ok and type(session.value)=='table' and session.value or nil
        local checked,coreCurrent=false,false
        if value and value.characterId==jane then
            checked,coreCurrent=pcall(function() return exports['feather-core']:IsSessionCurrent(target,value.sessionId,jane) end)
        end
        local detail={devMode=Config.DevMode==true,inventoryCharacterAmmoEnabled=Config.CharacterAmmunitionEnabled==true,
            inventoryState=InventoryReadiness.state,fixtureOptIn=GetConvar('feather_jane_saved_attachment_fixture','0')=='1',
            weaponsState=GetResourceState('feather-weapons'),proofState=GetResourceState('feather-weapons-native-proof'),
            sessionReadSucceeded=readSession,sessionOk=value~=nil,characterMatches=value and value.characterId==jane or false,
            coreCheckSucceeded=checked,coreCurrent=checked and coreCurrent==true or false}
        detail.allowed=detail.devMode and detail.inventoryCharacterAmmoEnabled and detail.inventoryState=='ready'
            and detail.fixtureOptIn and detail.weaponsState=='stopped' and detail.proofState=='stopped'
            and detail.characterMatches and detail.coreCurrent
        return detail
    end
    local function current()
        return gates().allowed==true
    end
    if mode=='inspect' then
        local detail=gates(); detail.noSQLWrites=true; detail.noNativeWrites=true
        return print('[InvJaneSavedAttachmentFixture] INSPECT '..json.encode(detail))
    end
    local called,result=pcall(function()
        if not current() then return Result.Err('saved_attachment_fixture_refused','Stopped opted-in current fixture required: '..json.encode(gates())) end
        local catalog,_,itemContract=CharacterAmmoNativePreview.Load()
        return TransactionAPI.Transaction({resource='feather-inventory',reason='native_saved_attachment_fixture'},function(tx)
            return NativeSavedAttachmentFixture.Apply(tx,current,mode,itemContract,catalog.weapons.repeater_carbine)
        end)
    end)
    print('[InvJaneSavedAttachmentFixture] '..(called and result and result.ok and ('PASS '..json.encode(result.value))
        or ('REFUSED '..tostring(called and result and result.error and result.error.message or result))))
end,true)

