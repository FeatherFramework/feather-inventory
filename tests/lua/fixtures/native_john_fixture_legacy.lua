-- Archived test-only body of the retired one-time multiplayer grant.
-- Never loaded by the resource; retained to reproduce its receipt/rollback tests.
NativeJohnMultiplayerFixture={}
function NativeJohnMultiplayerFixture.Apply(tx,current,limits,itemContract,definition)
    local john='4560a489-ca6c-11f1-9ad4-e0d55eaa2deb'
    local grantId='native-test-john-multiplayer-v1'
    local serial='FW-ALPHA-MULTI-JOHN-V1'
    local fingerprint=john..'|revolver_cattleman|1|ammo_revolver_regular|2|v1'
    local function refuse(message) return Result.Err('john_fixture_refused',message) end
    if current()~=true then return refuse('Current opted-in John fixture required.') end
    tx.query('INSERT IGNORE INTO inventory_grant_receipts (source_resource,grant_id,request_fingerprint) VALUES (?,?,?)',
        {'feather-inventory',grantId,fingerprint})
    local receipts=tx.query('SELECT request_fingerprint,result_json FROM inventory_grant_receipts WHERE source_resource=? AND grant_id=? FOR UPDATE',
        {'feather-inventory',grantId})
    local receipt=receipts and receipts[1]
    if not receipt or receipt.request_fingerprint~=fingerprint or current()~=true then return refuse('Fixture receipt conflict/current context lost.') end
    if receipt.result_json then
        local ok,value=pcall(json.decode,receipt.result_json)
        if not ok or type(value)~='table' or value.characterId~=john or value.serialNumber~=serial
            or type(value.itemId)~='number' or value.itemId<1 or value.itemId%1~=0 or value.itemRevision~=0
            or value.ammoQuantity~=2 then return refuse('Corrupt retained fixture receipt.') end
        value.replayed=true; return Result.Ok(value) -- historical result, never recreate spent/transferred units
    end
    local headers=tx.query('SELECT id FROM inventory WHERE character_id=? LIMIT 1 FOR UPDATE',{john})
    local inventoryId=headers and headers[1] and tonumber(headers[1].id)
    if not inventoryId then return refuse('John inventory missing.') end
    local ledger=tx.query('SELECT revision,pools FROM feather_character_ammunition WHERE character_id=? FOR UPDATE',{john})
    local row=ledger and ledger[1]
    local ok,pools=pcall(json.decode,row and row.pools or '')
    if not row or tonumber(row.revision)~=0 or not ok or type(pools)~='table' then return refuse('Fresh enrolled John ledger0 required.') end
    for id,value in pairs(pools) do if limits[id]==nil or value~=0 then return refuse('John carried ammunition must remain zero.') end end
    if type(limits.ammo_revolver_regular)~='number' then return refuse('Canonical revolver policy required.') end
    local items=tx.query('SELECT id FROM inventory_items WHERE inventory_id=? FOR UPDATE',{inventoryId})
    local equipment=tx.query('SELECT slot FROM character_equipment WHERE character_id=? FOR UPDATE',{john})
    if type(items)~='table' or next(items) or type(equipment)~='table' or next(equipment) then return refuse('Fresh empty John inventory/equipment required.') end
    local definitions=tx.query('SELECT id,name,type,instance_mode FROM items WHERE name IN (?,?) AND archived_at IS NULL FOR UPDATE',
        {'weapon_revolver_cattleman','ammo_revolver_regular'})
    local weaponId,ammoId
    for _,entry in ipairs(definitions or {}) do
        if entry.name=='weapon_revolver_cattleman' and entry.type=='item_weapon' and entry.instance_mode=='unique' then weaponId=tonumber(entry.id)
        elseif entry.name=='ammo_revolver_regular' and entry.type=='item_ammo' and entry.instance_mode=='stack' then ammoId=tonumber(entry.id) end
    end
    if not weaponId or not ammoId or definition.id~='revolver_cattleman' or definition.itemName~='weapon_revolver_cattleman' then return refuse('Canonical item definitions required.') end
    local metadata={schemaVersion=2,weaponDefinitionId=definition.id,serialNumber=serial,condition=100,quality=100,
        maintenance={degradation=0,permanentDegradation=0,damage=0,dirt=0,soot=0},
        ammo={ownership='character',type='ammo_revolver_regular'},attachments={},cosmetics={},
        flags={stolen=false,evidence=false,disabled=false},provenance={alphaMultiplayerJohnFixture=true}}
    if not itemContract.Validate(metadata,definition) or current()~=true then return refuse('Fixture metadata/current context invalid.') end
    local created=tx:CreateInstance(inventoryId,weaponId,metadata)
    if not created or not created.ok then return created or refuse('Fixture creation failed.') end
    if current()~=true then return refuse('Fixture authority changed after creation.') end
    local added=tx:AddQuantity(inventoryId,ammoId,2,{})
    if not added or not added.ok then return added or refuse('Fixture ammunition grant failed.') end
    local value={characterId=john,itemId=created.value.instanceId,itemRevision=created.value.revision,
        serialNumber=serial,ammoQuantity=2,replayed=false}
    if type(value.itemId)~='number' or value.itemId<1 or value.itemRevision~=0 then return refuse('Unexpected fixture identity/revision.') end
    local updated=tx.query('UPDATE inventory_grant_receipts SET result_json=? WHERE source_resource=? AND grant_id=?',
        {json.encode(value),'feather-inventory',grantId})
    if current()~=true or not updated or tonumber(updated.affectedRows or updated.affected_rows)~=1 then return refuse('Fixture completion failed.') end
    return Result.Ok(value)
end
