-- Real Inventory methods/guards and disposable database rows. No player items.
local scope='inventory-consumption-item-proof-v1'
local busy=false
local function Need(r) assert(type(r)=='table' and r.ok==true,json.encode(r)); return r.value end
local function ErrorCode(r,code) assert(type(r)=='table' and not r.ok and r.error and r.error.code==code,json.encode(r)) end
local function Id(tx,sql,p)
    local rows=tx.query(sql..' RETURNING id',p)
    return assert(tonumber(rows and rows[1] and rows[1].id),'Fixture ID missing.')
end
local function PrivateService(itemName)
    local env=setmetatable({Config={TrustedConsumptionCallers={[scope]={['proof.v1']={[itemName]=true}}}}},{__index=_G})
    local text=assert(LoadResourceFile(GetCurrentResourceName(),'server/services/consumption_once.lua'))
    assert(load(text,'@consumption-item-proof/private-service','t',env))()
    env.ConsumptionOnceAPI.Start()
    return env.ConsumptionOnceAPI
end
local function Run()
    local runId=assert(InventoryIdentity.NormalizeCharacterId(DB.value('SELECT UUID()')))
    local foreignCharacter=assert(InventoryIdentity.NormalizeCharacterId(DB.value('SELECT UUID()')))
    local name='proof_consume_'..runId:gsub('%-','')
    local guardName=scope..':'..runId
    DB.exec([[CREATE TABLE IF NOT EXISTS inventory_consumption_item_proofs (
        run_id CHAR(36) NOT NULL PRIMARY KEY, manifest_json LONGTEXT NOT NULL,
        phase VARCHAR(32) NOT NULL
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin]])
    local m={runId=runId,itemName=name,foreignCharacter=foreignCharacter,requests={}}
    local manifestJson
    for i=1,4 do m.requests[i]={operationId=assert(InventoryIdentity.NormalizeCharacterId(DB.value('SELECT UUID()')))} end
    print('[feather-inventory:consumption-item-proof] runId='..runId..'; creating isolated fixture.')
    Need(TransactionAPI.Transaction({resource=scope,reason='consumption_proof_setup'},function(tx)
        m.categoryId=Id(tx,'INSERT INTO categories (name) VALUES (?)',{name})
        m.definitionId=Id(tx,[[INSERT INTO items (name,display_name,max_quantity,max_stack_size,weight,usable,category_id,type,instance_mode)
            VALUES (?,?,10,10,0,0,?,'item_item','stack')]],{name,'Disposable consumption proof',m.categoryId})
        m.inventoryId=Id(tx,[[INSERT INTO inventory (uuid,name,max_weight,max_slots,character_id) VALUES (?,?,100,4,?)]],{runId,name,runId})
        m.foreignInventoryId=Id(tx,[[INSERT INTO inventory (uuid,name,max_weight,max_slots,character_id) VALUES (?,?,100,4,?)]],{foreignCharacter,name,foreignCharacter})
        m.itemIds=Need(tx:AddQuantity(m.inventoryId,m.definitionId,2,{consumptionProof=runId}))
        assert(#m.itemIds==2,'Expected two exact Inventory units.')
        for i,r in ipairs(m.requests) do
            r.characterId=i==2 and foreignCharacter or runId
            r.instanceId=m.itemIds[i==4 and 2 or 1]; r.definitionId=m.definitionId
            r.expectedRevision=i==3 and 1 or 0; r.itemName=name; r.purpose='proof.v1'; r.effectReference=runId
        end
        manifestJson=json.encode(m)
        tx.query('INSERT INTO inventory_consumption_item_proofs (run_id,manifest_json,phase) VALUES (?,?,?)',{runId,manifestJson,'running'})
        return Result.Ok(true)
    end))
    local service=PrivateService(name)
    local function Call(mode,i) return service[mode](m.requests[i],scope) end
    local function Units()
        return tonumber(DB.value('SELECT COUNT(*) FROM inventory_items WHERE inventory_id=? AND item_id=?',m.inventoryId,m.definitionId))
    end
    local registered=false
    local ok,failure=pcall(function()
        -- Production exported service must reject this private scope without
        -- touching the real allowlist. No global policy is temporarily enabled.
        ErrorCode(ConsumptionOnceAPI.Consume(m.requests[1],scope),'authorization_denied')
        ErrorCode(Call('Consume',2),'authorization_denied')
        ErrorCode(Call('Consume',3),'conflict')
        assert(Units()==2,'Refused ownership/revision checks removed an item.')
        local guardSeen=false
        Need(GuardsAPI.RegisterDestroyGuard(guardName,function(item,context)
            if item.id==m.itemIds[1] then
                assert(context.resource==scope and item.inventoryId==m.inventoryId)
                guardSeen=true; return false,'Disposable proof guard refusal.'
            end
            return true
        end))
        registered=true
        ErrorCode(Call('Consume',1),'denied')
        assert(guardSeen and Units()==2,'Real removal guard must veto before deletion.')
        ErrorCode(Call('Inspect',1),'not_found')
        GuardsAPI.UnregisterDestroyGuard(guardName); registered=false
        assert(Need(Call('Consume',1)).state=='consumed' and Units()==1)
        local replay=Need(Call('Consume',1)); assert(replay.replayed and replay.state=='consumed' and Units()==1)
        assert(Need(Call('Cancel',4)).state=='cancelled')
        assert(Need(Call('Consume',4)).state=='cancelled' and Units()==1)
        ErrorCode(Call('Inspect',2),'not_found'); ErrorCode(Call('Inspect',3),'not_found')
    end)
    if registered then GuardsAPI.UnregisterDestroyGuard(guardName) end
    assert(not GuardsAPI.HasRegisteredGuard(guardName),'Proof guard leaked.')
    assert(ok,failure) -- preserve journal/artifacts on failure, no broad cleanup
    Need(TransactionAPI.Transaction({resource=scope,reason='consumption_proof_cleanup'},function(tx)
        local journal=tx.query('SELECT manifest_json,phase FROM inventory_consumption_item_proofs WHERE run_id=? FOR UPDATE',{runId})
        assert(journal[1] and journal[1].phase=='running' and journal[1].manifest_json==manifestJson,'Proof manifest changed.')
        local remaining=tx.query('SELECT id,item_id,metadata FROM inventory_items WHERE inventory_id IN (?,?) FOR UPDATE',{m.inventoryId,m.foreignInventoryId})
        assert(#remaining==1 and tonumber(remaining[1].id)==m.itemIds[2] and tonumber(remaining[1].item_id)==m.definitionId,'Unexpected Inventory fixture contents.')
        assert(json.decode(remaining[1].metadata).consumptionProof==runId,'Unexpected fixture metadata.')
        Need(tx:RemoveInstances(m.inventoryId,m.definitionId,{m.itemIds[2]}))
        local references=tx.query('SELECT id FROM inventory_items WHERE item_id=? FOR UPDATE',{m.definitionId})
        assert(#references==0,'Proof definition has foreign references; cleanup refused.')
        for i,r in ipairs(m.requests) do
            local rows=tx.query('SELECT result_json FROM inventory_consumption_receipts WHERE source_resource=? AND operation_id=? FOR UPDATE',{scope,r.operationId})
            if i==1 or i==4 then
                assert(#rows==1 and json.decode(rows[1].result_json).effectReference==runId,'Proof receipt scope mismatch.')
                local changed=tx.query('DELETE FROM inventory_consumption_receipts WHERE source_resource=? AND operation_id=?',{scope,r.operationId})
                assert(tonumber(changed.affectedRows or changed.affected_rows)==1)
            else assert(#rows==0,'Rejected request unexpectedly has a receipt.') end
        end
        for _,entry in ipairs({{m.inventoryId,runId},{m.foreignInventoryId,foreignCharacter}}) do
            local changed=tx.query('DELETE FROM inventory WHERE id=? AND uuid=? AND character_id=?',{entry[1],entry[2],entry[2]})
            assert(tonumber(changed.affectedRows or changed.affected_rows)==1)
        end
        local changed=tx.query('DELETE FROM items WHERE id=? AND name=? AND category_id=?',{m.definitionId,name,m.categoryId})
        assert(tonumber(changed.affectedRows or changed.affected_rows)==1)
        changed=tx.query('DELETE FROM categories WHERE id=? AND name=?',{m.categoryId,name})
        assert(tonumber(changed.affectedRows or changed.affected_rows)==1)
        tx.query('UPDATE inventory_consumption_item_proofs SET phase=? WHERE run_id=?',{'cleared',runId})
        return Result.Ok(true)
    end))
    assert(Units()==0,'Proof units remain after cleanup.')
    return {runId=runId,state='cleared',realInventoryMethods=true,foreignCharacterRefused=true,revisionRefused=true,
        destroyGuardRefused=true,consumedOnce=true,cancellationFenced=true,productionAllowlistUnchanged=true,
        note='Isolated character inventories; trusted server caller membership check, not a live player-session ACL proof.'}
end
RegisterCommand('InvConsumptionItemProof',function(source,args)
    if source~=0 or Config.DevMode~=true then return end
    args=args or {}
    if #args~=1 or args[1]~='run' then print('[feather-inventory:consumption-item-proof] InvConsumptionItemProof run'); return end
    if busy or not InventoryReadiness or InventoryReadiness.state~='ready' then
        print('[feather-inventory:consumption-item-proof] refused: busy or Inventory not ready.'); return
    end
    busy=true
    CreateThread(function()
        local ok,value=pcall(Run); busy=false
        print('[feather-inventory:consumption-item-proof] '..json.encode({ok=ok,value=ok and value or nil,error=not ok and tostring(value) or nil}))
    end)
end,true)
