-- Console-only, opt-in integration proof. Real receipt SQL/locks/transactions;
-- synthetic item rows and eligibility adapter, never player inventory.
local scope='inventory-consumption-proof-v1'
local busy=false
local unresolved=false
local resourceEpoch
local function Epoch()
    resourceEpoch=resourceEpoch or assert(InventoryIdentity.NormalizeCharacterId(DB.value('SELECT UUID()')))
    return resourceEpoch
end
local function Required(result)
    assert(type(result)=='table' and result.ok==true,json.encode(result))
    return result.value
end
local function Uuid(v)
    return InventoryIdentity.NormalizeCharacterId(v)
end
local function Schema()
    DB.exec([[CREATE TABLE IF NOT EXISTS inventory_consumption_proof_items (
        id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
        run_id CHAR(36) NOT NULL, character_id CHAR(36) NOT NULL,
        KEY proof_run(run_id)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin]])
    DB.exec([[CREATE TABLE IF NOT EXISTS inventory_consumption_proof_runs (
        run_id CHAR(36) NOT NULL PRIMARY KEY, manifest_json LONGTEXT NOT NULL,
        phase VARCHAR(32) NOT NULL
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin]])
end
local function Service(runId,options)
    options=options or {}
    local source=assert(LoadResourceFile(GetCurrentResourceName(),'server/services/consumption_once.lua'))
    local env=setmetatable({Config={TrustedConsumptionCallers={[scope]={['proof.v1']={proof_unit=true}}}},
        TransactionAPI={}}, {__index=_G})
    env.TransactionAPI.Transaction=function(context,body)
        assert(context.resource==scope and context.idempotencyKey==nil)
        local result
        local committed=DB.transaction(function(connection)
            local tx={}
            local function raw(sql,p) return connection.raw(sql,table.unpack(p or {},1,CountPlaceholders(sql))) end
            local connectionId=connection.value('SELECT CONNECTION_ID()')
            if options.connections then options.connections[connectionId]=true end
            tx.query=function(sql,p)
                if sql:find('SELECT id FROM inventory WHERE',1,true) then
                    -- Explicit synthetic eligibility seam; real character ACL is NOT tested.
                    return {{id=1}}
                elseif sql:find('SELECT archived_at FROM items WHERE',1,true) then return {{}} end
                if options.failSave and sql:find('UPDATE inventory_consumption_receipts',1,true) then return {affectedRows=0} end
                local rows=raw(sql,p)
                if options.hold and sql:find('INSERT IGNORE INTO inventory_consumption_receipts',1,true) then
                    options.hold=false
                    -- Deliberately hold this proof receipt lock to overlap competitors.
                    Wait(250)
                end
                return rows
            end
            function tx:GetItemForUpdate(id)
                local rows=raw('SELECT id,character_id FROM inventory_consumption_proof_items WHERE id=? AND run_id=? FOR UPDATE',{id,runId}) or {}
                if not rows[1] then return Result.Err('not_found','Proof unit absent.') end
                assert(rows[1].character_id==runId,'Foreign proof character.')
                return Result.Ok({id=tonumber(rows[1].id),inventoryId=1,revision=0,
                    definition={id=1,name='proof_unit',type='item_item',instanceMode='stack'}})
            end
            function tx:RemoveInstances(inventoryId,definitionId,ids)
                assert(inventoryId==1 and definitionId==1 and #ids==1)
                local changed=raw('DELETE FROM inventory_consumption_proof_items WHERE id=? AND run_id=?',{ids[1],runId})
                assert(tonumber(changed.affectedRows or changed.affected_rows)==1,'Proof unit delete mismatch.')
                return Result.Ok(ids)
            end
            result=body(tx)
            return result.ok==true
        end)
        if options.dropAcknowledgement and committed==true then error('Simulated lost commit reply after actual commit.') end
        if committed~=true then return result and not result.ok and result or Result.Err('internal','Proof transaction did not commit.') end
        return result
    end
    assert(load(source,'@consumption-proof/private-service','t',env))()
    env.ConsumptionOnceAPI.Start()
    return env.ConsumptionOnceAPI
end
local function Call(service,mode,request) return service[mode](request,scope) end
local function Parallel(first,second)
    local results,failures,done={}, {},0
    for i,fn in ipairs({first,second}) do
        CreateThread(function()
            local ok,value=pcall(fn)
            if ok then results[i]=value else failures[i]=tostring(value) end
            done=done+1
        end)
    end
    local deadline=GetGameTimer()+30000
    while done<2 and GetGameTimer()<deadline do Wait(50) end
    if done~=2 then unresolved=true; error('Proof workers timed out; fixtures retained. Restart before further proof commands.') end
    assert(not next(failures),json.encode(failures))
    return results[1],results[2]
end
local function Items(runId)
    return tonumber(DB.value('SELECT COUNT(*) FROM inventory_consumption_proof_items WHERE run_id=?',runId))
end
local function Run()
    Schema()
    local runId=assert(Uuid(DB.value('SELECT UUID()')))
    local requests={}
    for i=1,4 do
        DB.exec('INSERT INTO inventory_consumption_proof_items (run_id,character_id) VALUES (?,?)',runId,runId)
        local rows=DB.query('SELECT id FROM inventory_consumption_proof_items WHERE run_id=? ORDER BY id',runId)
        requests[i]={operationId=assert(Uuid(DB.value('SELECT UUID()'))),characterId=runId,
            instanceId=tonumber(rows[#rows].id),definitionId=1,expectedRevision=0,itemName='proof_unit',purpose='proof.v1',effectReference=runId}
    end
    -- Manifest committed before consumption, retained through any failed gate.
    DB.exec('INSERT INTO inventory_consumption_proof_runs (run_id,manifest_json,phase) VALUES (?,?,?)',runId,
        json.encode({requests=requests,resourceEpoch=Epoch()}),'running')
    print('[feather-inventory:consumption-proof] runId='..runId..'; disposable fixture created.')
    local connections={}
    local first=Service(runId,{hold=true,connections=connections})
    local second=Service(runId,{connections=connections})
    local a,b=Parallel(function() return Call(first,'Consume',requests[1]) end,function() return Call(second,'Consume',requests[1]) end)
    a,b=Required(a),Required(b)
    assert(a.state=='consumed' and b.state=='consumed' and a.replayed~=b.replayed and Items(runId)==3,'Same-key consume must remove once.')
    local connectionCount=0; for _ in pairs(connections) do connectionCount=connectionCount+1 end
    assert(connectionCount>=2,'Separate MariaDB connections not demonstrated.')
    local cancelFirst=Service(runId,{hold=true})
    a,b=Parallel(function() return Call(cancelFirst,'Cancel',requests[2]) end,function() return Call(second,'Consume',requests[2]) end)
    a,b=Required(a),Required(b)
    assert(a.state==b.state and a.replayed~=b.replayed,'Cancel/consume must have one terminal winner.')
    local raceConsumed=a.state=='consumed'
    assert(Items(runId)==(raceConsumed and 2 or 3),'Cancel race item count mismatch.')
    local rollback=Service(runId,{failSave=true})
    assert(Call(rollback,'Consume',requests[3]).error.code=='outcome_unknown')
    assert(Call(second,'Inspect',requests[3]).error.code=='not_found','Rolled back receipt must be absent.')
    assert(Items(runId)==(raceConsumed and 2 or 3),'Rollback must preserve unit.')
    Required(Call(second,'Cancel',requests[3]))
    local lost=Service(runId,{dropAcknowledgement=true})
    assert(Call(lost,'Consume',requests[4]).error.code=='outcome_unknown')
    assert(Required(Call(second,'Inspect',requests[4])).state=='consumed','Actual commit must survive dropped acknowledgement.')
    assert(Items(runId)==(raceConsumed and 1 or 2),'Lost-ack item count mismatch.')
    DB.exec('UPDATE inventory_consumption_proof_runs SET phase=? WHERE run_id=?','awaiting_restart',runId)
    return {runId=runId,state='awaiting_restart',separateConnections=true,sameKeyConsume=true,cancelRace=true,
        rollback=true,lostCommitAcknowledgement=true,syntheticItemsOnly=true,
        next='After restart feather-inventory: InvConsumptionProof verify '..runId}
end
local function Verify(runId)
    Schema()
    local rows=DB.query('SELECT manifest_json,phase FROM inventory_consumption_proof_runs WHERE run_id=?',runId) or {}
    assert(rows[1] and rows[1].phase=='awaiting_restart','Exact completed proof run required.')
    local manifest=json.decode(rows[1].manifest_json)
    assert(type(manifest)=='table' and Uuid(manifest.resourceEpoch) and manifest.resourceEpoch~=Epoch(),
        'Restart feather-inventory before durable replay verification.')
    local requests=manifest.requests
    assert(type(requests)=='table' and #requests==4,'Invalid proof manifest.')
    local service=Service(runId)
    local remaining=0
    for i,r in ipairs(requests) do
        assert(r.characterId==runId and r.effectReference==runId and Uuid(r.operationId),'Invalid proof scope.')
        local value=Required(Call(service,'Inspect',r))
        if i==1 or i==4 then assert(value.state=='consumed') elseif i==3 then assert(value.state=='cancelled') end
        if value.state=='cancelled' then remaining=remaining+1 end
        local replay=Required(Call(service,'Consume',r))
        assert(replay.replayed and replay.state==value.state,'Durable terminal replay mismatch.')
    end
    assert(Items(runId)==remaining,'Proof leftovers mismatch; retained.')
    assert(DB.transaction(function(tx)
        for _,r in ipairs(requests) do
            local deleted=tx.exec('DELETE FROM inventory_consumption_receipts WHERE source_resource=? AND operation_id=?',scope,r.operationId)
            assert(tonumber(deleted)==1,'Exact proof receipt cleanup mismatch.')
        end
        local deleted=tx.exec('DELETE FROM inventory_consumption_proof_items WHERE run_id=?',runId)
        assert(tonumber(deleted)==remaining,'Exact proof item cleanup mismatch.')
        tx.exec('UPDATE inventory_consumption_proof_runs SET phase=? WHERE run_id=?','cleared',runId)
        return true
    end)==true,'Proof cleanup did not commit.')
    assert(Items(runId)==0,'Proof units remain.')
    return {runId=runId,state='cleared',durableReplay=true,syntheticItemsOnly=true,
        note='Real receipt SQL; item/character eligibility uses a synthetic adapter, not player inventory.'}
end
RegisterCommand('InvConsumptionProof',function(source,args)
    if source~=0 or Config.DevMode~=true then return end
    args=args or {}
    if not ((#args==1 and args[1]=='run') or (#args==2 and args[1]=='verify' and Uuid(args[2]))) then
        print('[feather-inventory:consumption-proof] InvConsumptionProof run | verify <runId>'); return
    end
    if busy or unresolved or not InventoryReadiness or InventoryReadiness.state~='ready' then
        print('[feather-inventory:consumption-proof] refused: busy or Inventory not ready.'); return
    end
    busy=true
    CreateThread(function()
        local ok,value=pcall(function() return args[1]=='run' and Run() or Verify(args[2]:lower()) end)
        busy=false
        print('[feather-inventory:consumption-proof] '..json.encode({ok=ok,value=ok and value or nil,error=not ok and tostring(value) or nil}))
    end)
end,true)
