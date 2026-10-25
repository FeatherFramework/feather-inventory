-- Additive, server-only consumption. Never pass an idempotencyKey to the
-- transaction runner: every attempt must read the durable receipt.
ConsumptionOnceAPI = {}
local ready=false
local fields={'operationId','characterId','instanceId','definitionId','expectedRevision','itemName','purpose','effectReference'}
local function Integer(v,min) return type(v)=='number' and v%1==0 and v>=min and v<=9007199254740991 end
local function Validate(request,resource)
    local policy=(Config.TrustedConsumptionCallers or {})[resource or '']
    if type(policy)~='table' then return Result.Err('authorization_denied','Consumption caller is not trusted.') end
    if type(request)~='table' then return Result.Err('invalid_input','Consumption request required.') end
    local r={}
    for k in pairs(request) do
        local known=false; for _,name in ipairs(fields) do if k==name then known=true; break end end
        if not known then return Result.Err('invalid_input','Unexpected consumption field.') end
    end
    for _,name in ipairs(fields) do r[name]=request[name] end
    r.characterId=InventoryIdentity.NormalizeCharacterId(r.characterId)
    r.operationId=InventoryIdentity.NormalizeCharacterId(r.operationId)
    if not r.characterId or not r.operationId or not Integer(r.instanceId,1)
        or not Integer(r.definitionId,1) or not Integer(r.expectedRevision,0)
        or type(r.itemName)~='string' or #r.itemName>100 or not r.itemName:match('^[a-z0-9_]+$')
        or type(r.purpose)~='string' or #r.purpose>64 or not r.purpose:match('^[a-z0-9_:.%-]+$')
        or type(r.effectReference)~='string' or #r.effectReference>128 or not r.effectReference:match('^[a-zA-Z0-9_:.%-]+$') then
        return Result.Err('invalid_input','Invalid consumption identity or effect reference.')
    end
    if type(policy[r.purpose])~='table' or policy[r.purpose][r.itemName]~=true then
        return Result.Err('authorization_denied','Consumption item/purpose is not allowed.')
    end
    -- Fixed order, delimiter excluded from every string field.
    local parts={}; for _,name in ipairs(fields) do
        parts[#parts+1]=type(r[name])=='number' and string.format('%.0f',r[name]) or r[name]
    end
    r.fingerprint=table.concat(parts,'|')
    return Result.Ok(r)
end

function ConsumptionOnceAPI.Start()
    ready=false
    DB.exec([[CREATE TABLE IF NOT EXISTS inventory_consumption_receipts (
        source_resource VARCHAR(100) NOT NULL,
        operation_id CHAR(36) NOT NULL,
        request_fingerprint VARCHAR(700) NOT NULL,
        result_json LONGTEXT NULL,
        created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
        PRIMARY KEY (source_resource,operation_id)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin]])
    local columns=DB.query('SHOW FULL COLUMNS FROM inventory_consumption_receipts') or {}
    local found={}; for _,row in ipairs(columns) do found[row.Field]=row end
    for name,kind in pairs({source_resource='varchar(100)',operation_id='char(36)',request_fingerprint='varchar(700)',result_json='longtext',created_at='timestamp'}) do
        local row=found[name]
        assert(row and row.Type==kind,'Consumption receipt column is incompatible: '..name)
        assert(row.Null==(name=='result_json' and 'YES' or 'NO'),'Consumption receipt nullability is incompatible: '..name)
        if name~='created_at' then assert(row.Collation=='utf8mb4_bin','Consumption receipt requires binary collation.') end
    end
    local tables=DB.query("SELECT ENGINE FROM information_schema.TABLES WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='inventory_consumption_receipts'") or {}
    assert(tables[1] and tables[1].ENGINE=='InnoDB','Consumption receipts require InnoDB.')
    local indexes=DB.query('SHOW INDEX FROM inventory_consumption_receipts') or {}
    local primary={}; for _,row in ipairs(indexes) do if row.Key_name=='PRIMARY' then primary[tonumber(row.Seq_in_index)]=row.Column_name end end
    assert(#primary==2 and primary[1]=='source_resource' and primary[2]=='operation_id','Consumption receipt primary key is incompatible.')
    ready=true
end
function ConsumptionOnceAPI.Contract()
    return {contractVersion=1,ready=ready,durableConsumption=ready and 1 or 0}
end

local function Operation(request,resource,mode)
    if not ready then return Result.Err('not_ready','Consumption receipts are not ready.') end
    local validated=Validate(request,resource); if not validated.ok then return validated end
    local r=validated.value
    local called,result=pcall(TransactionAPI.Transaction,{resource=resource,reason='character_consumption_'..mode,correlationId=r.operationId},function(tx)
        local inserted=false
        if mode~='inspect' then
            local write=tx.query('INSERT IGNORE INTO inventory_consumption_receipts (source_resource,operation_id,request_fingerprint) VALUES (?,?,?)',
                {resource,r.operationId,r.fingerprint})
            inserted=write and tonumber(write.affectedRows or write.affected_rows)==1
        end
        local rows=tx.query('SELECT request_fingerprint,result_json FROM inventory_consumption_receipts WHERE source_resource=? AND operation_id=? FOR UPDATE',
            {resource,r.operationId}) or {}
        local receipt=rows[1]
        if not receipt then return Result.Err('not_found','Consumption receipt is absent; no outcome inferred.') end
        if receipt.request_fingerprint~=r.fingerprint then return Result.Err('receipt_conflict','Operation is bound to another request.') end
        if receipt.result_json then
            local decoded,v=pcall(json.decode,receipt.result_json)
            if not decoded or type(v)~='table' or v.contractVersion~=1 or v.sourceResource~=resource
                or (v.state~='consumed' and v.state~='cancelled') or not Integer(v.inventoryId,0)
                or (v.state=='consumed' and v.inventoryId==0) or (v.state=='cancelled' and v.inventoryId~=0) then
                return Result.Err('receipt_invalid','Stored consumption receipt is invalid.')
            end
            for _,name in ipairs(fields) do if v[name]~=r[name] then return Result.Err('receipt_invalid','Stored consumption binding is invalid.') end end
            v.replayed=true; return Result.Ok(v)
        end
        -- A pending row cannot survive a successful commit in this protocol.
        if not inserted then return Result.Err('receipt_invalid','Incomplete consumption receipt retained.') end
        local inventoryId=0
        if mode=='consume' then
            local itemResult=tx:GetItemForUpdate(r.instanceId); if not itemResult.ok then return itemResult end
            local item=itemResult.value
            local inventories=tx.query('SELECT id FROM inventory WHERE character_id=? LIMIT 1 FOR UPDATE',{r.characterId}) or {}
            if not inventories[1] or tonumber(inventories[1].id)~=item.inventoryId then
                return Result.Err('authorization_denied','Item is not in the character inventory.')
            end
            if item.definition.id~=r.definitionId or item.definition.name~=r.itemName or item.revision~=r.expectedRevision then
                return Result.Err('conflict','Item identity or revision changed.')
            end
            if item.definition.instanceMode~='stack' or item.definition.type~='item_item' then
                return Result.Err('item_unavailable','Only ordinary stack instances can be consumed.')
            end
            local definition=tx.query('SELECT archived_at FROM items WHERE id=? FOR UPDATE',{r.definitionId}) or {}
            if not definition[1] or definition[1].archived_at~=nil then return Result.Err('item_unavailable','Item definition is archived or absent.') end
            local removed=tx:RemoveInstances(item.inventoryId,r.definitionId,{r.instanceId})
            if not removed.ok then return removed end
            inventoryId=item.inventoryId
        end
        local v={contractVersion=1,sourceResource=resource,state=mode=='consume' and 'consumed' or 'cancelled',inventoryId=inventoryId,replayed=false}
        for _,name in ipairs(fields) do v[name]=r[name] end
        local saved=tx.query('UPDATE inventory_consumption_receipts SET result_json=? WHERE source_resource=? AND operation_id=? AND result_json IS NULL',
            {json.encode(v),resource,r.operationId})
        if not saved or tonumber(saved.affectedRows or saved.affected_rows)~=1 then
            return Result.Err('internal','Consumption receipt was not saved; transaction must roll back.')
        end
        return Result.Ok(v)
    end)
    -- The legacy runner cannot distinguish every commit-ack failure. Never
    -- advertise a definitive rollback to economic consumers in that case.
    if not called or type(result)~='table' or (not result.ok and result.error and result.error.code=='internal') then
        return Result.Err('outcome_unknown','Inspect or retry the exact consumption operation; do not replace its ID.')
    end
    return result
end
function ConsumptionOnceAPI.Consume(request,resource) return Operation(request,resource,'consume') end
function ConsumptionOnceAPI.Cancel(request,resource) return Operation(request,resource,'cancel') end
function ConsumptionOnceAPI.Inspect(request,resource) return Operation(request,resource,'inspect') end
