-- Narrow development fixture only. Never enables a production consumption
-- caller. Only bcc-stables, exact reserved UUIDs and this manifest may use it.
StablesCareConsumptionProof={}
local P=StablesCareConsumptionProof
local KEY='stables-care-v1'
local NAME='proof_stables_care_receipt_v1'
local function Id(n) return ('bccb%04x-0000-4000-8000-000000000001'):format(n) end
local function Need(r) assert(type(r)=='table' and r.ok==true,json.encode(r)); return r.value end
local function Allowed(resource) return resource=='bcc-stables' and Config.DevMode==true and InventoryReadiness.state=='ready' end
local function Manifest()
    local row=DB.one('SELECT manifest_json,phase FROM inventory_stables_care_proof WHERE proof_key=?',KEY)
    assert(row and row.phase=='active','Exact active care fixture required.')
    local m=json.decode(row.manifest_json)
    assert(type(m)=='table' and m.characterId==Id(1) and m.horseId==Id(2) and m.itemName==NAME,'Invalid care fixture manifest.')
    for _,k in ipairs({'instanceId','definitionId','inventoryId','categoryId'}) do
        assert(type(m[k])=='number' and m[k]%1==0 and m[k]>0 and m[k]<=9007199254740991,'Invalid care fixture numeric identity.')
    end
    return m
end
local function Request(m,index)
    return {operationId=Id(10+index),characterId=Id(1),instanceId=m.instanceId,definitionId=m.definitionId,
        expectedRevision=0,itemName=NAME,purpose='stables.care.v1',effectReference=Id(2)..':policy1'}
end
local function Service()
    local env=setmetatable({Config={TrustedConsumptionCallers={['bcc-stables']={['stables.care.v1']={[NAME]=true}}}}},{__index=_G})
    assert(load(assert(LoadResourceFile(GetCurrentResourceName(),'server/services/consumption_once.lua')),'@stables-care-proof/private-consumption','t',env))()
    env.ConsumptionOnceAPI.Start()
    return env.ConsumptionOnceAPI
end
local function Prepare()
    DB.exec([[CREATE TABLE IF NOT EXISTS inventory_stables_care_proof (
        proof_key VARCHAR(32) NOT NULL PRIMARY KEY, manifest_json LONGTEXT NOT NULL, phase VARCHAR(16) NOT NULL
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin]])
    local m=Need(TransactionAPI.Transaction({resource='feather-inventory',reason='stables_care_proof_setup'},function(tx)
        if tx.query('SELECT phase FROM inventory_stables_care_proof WHERE proof_key=? FOR UPDATE',{KEY})[1] then
            return Result.Err('fixture_exists','Care integration fixture already exists; inspect before retry.')
        end
        local function Insert(sql,p)
            local rows=tx.query(sql..' RETURNING id',p)
            return assert(tonumber(rows and rows[1] and rows[1].id),'Fixture insert ID missing.')
        end
        local v={characterId=Id(1),horseId=Id(2),itemName=NAME}
        v.categoryId=Insert('INSERT INTO categories (name) VALUES (?)',{NAME})
        v.definitionId=Insert([[INSERT INTO items (name,display_name,max_quantity,max_stack_size,weight,usable,category_id,type,instance_mode)
            VALUES (?,?,10,10,0,0,?,'item_item','stack')]],{NAME,'Disposable Stables care proof',v.categoryId})
        v.inventoryId=Insert('INSERT INTO inventory (uuid,name,max_weight,max_slots,character_id) VALUES (?,?,100,4,?)',{Id(1),NAME,Id(1)})
        local ids=Need(tx:AddQuantity(v.inventoryId,v.definitionId,1,{stablesCareProof=KEY}))
        assert(#ids==1); v.instanceId=ids[1]
        tx.query('INSERT INTO inventory_stables_care_proof (proof_key,manifest_json,phase) VALUES (?,?,?)',{KEY,json.encode(v),'active'})
        return Result.Ok(v)
    end))
    return Result.Ok({consumptionRequest=Request(m,1),cancellationRequest=Request(m,2)})
end
local function Clear()
    local m=Manifest(); local service=Service()
    assert(Need(service.Inspect(Request(m,1),'bcc-stables')).state=='consumed')
    assert(Need(service.Inspect(Request(m,2),'bcc-stables')).state=='cancelled')
    return TransactionAPI.Transaction({resource='feather-inventory',reason='stables_care_proof_cleanup'},function(tx)
        local rows=tx.query('SELECT manifest_json,phase FROM inventory_stables_care_proof WHERE proof_key=? FOR UPDATE',{KEY})
        assert(rows[1] and rows[1].phase=='active')
        local saved=json.decode(rows[1].manifest_json)
        for k,v in pairs(m) do assert(saved[k]==v,'Fixture manifest changed.') end
        assert(#tx.query('SELECT id FROM inventory_items WHERE inventory_id=? OR item_id=? FOR UPDATE',{m.inventoryId,m.definitionId})==0,'Unexpected item reference; cleanup refused.')
        for i=1,2 do
            local request=Request(m,i)
            local receipt=tx.query('SELECT result_json FROM inventory_consumption_receipts WHERE source_resource=? AND operation_id=? FOR UPDATE',{'bcc-stables',request.operationId})[1]
            assert(receipt,'Fixture receipt absent.')
            local v=json.decode(receipt.result_json)
            for k,x in pairs(request) do assert(v[k]==x,'Receipt binding changed.') end
            assert(v.sourceResource=='bcc-stables' and v.contractVersion==1 and v.state==(i==1 and 'consumed' or 'cancelled')
                and v.inventoryId==(i==1 and m.inventoryId or 0),'Receipt state changed.')
            local changed=tx.query('DELETE FROM inventory_consumption_receipts WHERE source_resource=? AND operation_id=?',{'bcc-stables',request.operationId})
            assert(tonumber(changed.affectedRows or changed.affected_rows)==1)
        end
        for _,spec in ipairs({{'DELETE FROM inventory WHERE id=? AND uuid=? AND character_id=?',{m.inventoryId,Id(1),Id(1)}},
            {'DELETE FROM items WHERE id=? AND name=? AND category_id=?',{m.definitionId,NAME,m.categoryId}},
            {'DELETE FROM categories WHERE id=? AND name=?',{m.categoryId,NAME}}}) do
            local changed=tx.query(spec[1],spec[2]); assert(tonumber(changed.affectedRows or changed.affected_rows)==1)
        end
        local changed=tx.query('UPDATE inventory_stables_care_proof SET phase=? WHERE proof_key=? AND phase=?',{'cleared',KEY,'active'})
        assert(tonumber(changed.affectedRows or changed.affected_rows)==1)
        return Result.Ok({cleared=true,productionAllowlistUnchanged=true})
    end)
end
-- The ordinary Inspect export may read ONLY these exact proof receipts while
-- the durable fixture manifest is active. No Consume/Cancel bypass is added.
function P.TryInspect(request,resource)
    if not Allowed(resource) or type(request)~='table' or (request.operationId~=Id(11) and request.operationId~=Id(12)) then return false end
    local called,result=pcall(function()
        local m=Manifest(); local expected=Request(m,request.operationId==Id(11) and 1 or 2)
        for k in pairs(request) do assert(expected[k]~=nil,'Unexpected proof request field.') end
        for k,v in pairs(expected) do assert(request[k]==v,'Not the exact proof request.') end
        return Service().Inspect(expected,'bcc-stables')
    end)
    return true,called and result or Result.Err('fixture_refused','Exact active care proof receipt required; production policy unchanged.')
end
function P.Step(action,resource)
    if not Allowed(resource) then return Result.Err('authorization_denied','Development Stables caller required.') end
    if action~='prepare' and action~='consume' and action~='cancel' and action~='clear' and action~='inspect' then return Result.Err('invalid_input','Unknown care proof step.') end
    local called,result=pcall(function()
        if action=='inspect' then
            local row=DB.one('SELECT manifest_json,phase FROM inventory_stables_care_proof WHERE proof_key=?',KEY)
            if not row then return Result.Ok({inspectionOnly=true,state='empty'}) end
            local m=json.decode(row.manifest_json)
            assert(m.characterId==Id(1) and m.horseId==Id(2) and m.itemName==NAME)
            local receipts={}
            for i=1,2 do
                local saved=DB.one('SELECT result_json FROM inventory_consumption_receipts WHERE source_resource=? AND operation_id=?','bcc-stables',Id(10+i))
                receipts[i]=saved and json.decode(saved.result_json).state or 'absent'
            end
            return Result.Ok({inspectionOnly=true,state=row.phase,receiptStates=receipts,
                remainingItems=tonumber(DB.value('SELECT COUNT(*) FROM inventory_items WHERE inventory_id=? OR item_id=?',m.inventoryId,m.definitionId))})
        end
        if action=='prepare' then return Prepare() end
        if action=='clear' then return Clear() end
        local m=Manifest(); local service=Service()
        local receipt=action=='consume' and service.Consume(Request(m,1),'bcc-stables') or service.Cancel(Request(m,2),'bcc-stables')
        local value=Need(receipt)
        assert(value.state==(action=='consume' and 'consumed' or 'cancelled'))
        -- No receipt returned: Stables must recover via ordinary inspection.
        return Result.Ok({committed=true,state=value.state})
    end)
    return called and result or Result.Err('fixture_outcome_unknown',tostring(result)..'; retain both resource fixtures.')
end
