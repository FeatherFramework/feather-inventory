-- Inactive transaction primitive: not in services wildcard, no export/command.
-- Caller must own the Inventory transaction and exact released-owner authority.
-- Requires pre-existing durable spend AND verified binding records; never creates
-- origin proof, observes client pickups, writes carried ammo or calls natives.
local C={}
local function copy(v) if type(v)~='table' then return v end; local r={}; for k,x in pairs(v) do r[k]=copy(x) end; return r end
local function equal(a,b)
    if type(a)~=type(b) then return false end; if type(a)~='table' then return a==b end
    for k,v in pairs(a) do if not equal(v,b[k]) then return false end end
    for k in pairs(b) do if a[k]==nil then return false end end; return true
end
local function text(v,max) return type(v)=='string' and #v>0 and #v<=max and not v:find('%c') end
local function int(v,min) return type(v)=='number' and v>=min and v<math.huge and v%1==0 end
local function callable(v) return type(v)=='function' or (type(v)=='table' and type(rawget(v,'__cfx_functionReference'))=='string') end
local function refused() return Result.Err('throwable_recovery_refused','Verified unclaimed spend/binding/current authority required.') end
local function read(tx,namespace,key)
    local rows=tx.query('SELECT request_fingerprint,result_json FROM inventory_grant_receipts WHERE source_resource=? AND grant_id=? FOR UPDATE',{namespace,key})
    local row=rows and rows[1]
    if not row or not row.result_json then return nil end
    local ok,value=pcall(json.decode,row.result_json)
    return ok and type(value)=='table' and value or nil
end
function C.Apply(tx,context,plan,current)
    if type(context)~='table' or type(plan)~='table' or not callable(current) or current()~=true
        or plan.version~=1 or plan.kind~='projectile_binding_plan' or plan.units~=1
        or plan.pickupCredits~=false or plan.requiresAtomicSingleClaim~=true
        or plan.requiresCurrentProjectile~=true or plan.requiresPickupProximity~=true
        or not text(plan.spendReceiptId,64) or not text(plan.projectileInstanceId,64) or not text(plan.originEventId,64)
        or type(plan.identity)~='table' or context.characterId~=plan.identity.characterId
        or context.sessionId~=plan.identity.sessionId or context.epoch~=plan.identity.epoch
        or not text(context.characterId,36) or not int(plan.itemId,1) or not int(plan.itemRevision,0)
        or not text(plan.serialNumber,128) then return refused() end
    context,plan=copy(context),copy(plan)
    local headers=tx.query('SELECT id FROM inventory WHERE character_id=? LIMIT 1 FOR UPDATE',{context.characterId})
    local inventoryId=headers and headers[1] and tonumber(headers[1].id)
    if not int(inventoryId,1) or current()~=true then return refused() end
    local spend=read(tx,'native-tomahawk-spend-v1',plan.spendReceiptId)
    local binding=read(tx,'native-tomahawk-binding-v1',plan.spendReceiptId)
    local candidate=spend and spend.candidate
    if not spend or (spend.phase~='committed_unclaimed' and spend.phase~='claimed') or not candidate
        or spend.receiptId~=plan.spendReceiptId or not equal(candidate.identity,plan.identity)
        or not equal(candidate.key,plan.spendKey) or candidate.itemId~=plan.itemId
        or candidate.itemRevision~=plan.itemRevision or candidate.serialNumber~=plan.serialNumber
        or candidate.units~=1 or candidate.definitionId~='throwable_tomahawk'
        or not binding or binding.verified~=true or not equal(binding.plan,plan) or current()~=true then return refused() end
    -- Three uniqueness boundaries in the existing durable receipt table. Lock
    -- order is deterministic; a second spend cannot reuse projectile or origin.
    local keys={'spend:'..plan.spendReceiptId,'projectile:'..plan.projectileInstanceId,'origin:'..plan.originEventId}
    table.sort(keys)
    local parts={context.characterId,plan.spendReceiptId,plan.projectileInstanceId,plan.originEventId,tostring(plan.itemId)}
    local framed={}; for _,v in ipairs(parts) do framed[#framed+1]=#v..':'..v end
    local fingerprint=table.concat(framed)
    if #fingerprint>300 then return refused() end
    local completed,stored=0,nil
    for _,key in ipairs(keys) do
        tx.query('INSERT IGNORE INTO inventory_grant_receipts (source_resource,grant_id,request_fingerprint) VALUES (?,?,?)',
            {'native-tomahawk-claim-v1',key,fingerprint})
        local rows=tx.query('SELECT request_fingerprint,result_json FROM inventory_grant_receipts WHERE source_resource=? AND grant_id=? FOR UPDATE',
            {'native-tomahawk-claim-v1',key})
        local row=rows and rows[1]
        if not row or row.request_fingerprint~=fingerprint then return refused() end
        if row.result_json then
            local ok,result=pcall(json.decode,row.result_json)
            if not ok or type(result)~='table' or not equal(result.plan,plan) or result.quantity~=1
                or result.characterId~=context.characterId or result.inventoryId~=inventoryId
                or result.itemName~='ammo_tomahawk_regular' then return refused() end
            if stored and not equal(stored,result) then return refused() end
            stored=result; completed=completed+1
        end
    end
    if current()~=true then return refused() end
    if completed==3 and spend.phase=='claimed' then stored.replayed=true; return Result.Ok(stored) end
    if completed~=0 or spend.phase~='committed_unclaimed' then return refused() end
    local defs=tx.query('SELECT id,type,instance_mode,archived_at FROM items WHERE name=? LIMIT 1 FOR UPDATE',{'ammo_tomahawk_regular'})
    local def=defs and defs[1]
    if not def or not int(tonumber(def.id),1) or def.type~='item_ammo' or def.instance_mode~='stack'
        or def.archived_at~=nil or current()~=true then return refused() end
    local delivered=tx:AddQuantity(inventoryId,tonumber(def.id),1)
    if not delivered or not delivered.ok then return delivered or refused() end
    local result={plan=copy(plan),characterId=context.characterId,inventoryId=inventoryId,
        itemName='ammo_tomahawk_regular',quantity=1,replayed=false}
    for _,key in ipairs(keys) do
        local updated=tx.query('UPDATE inventory_grant_receipts SET result_json=? WHERE source_resource=? AND grant_id=?',
            {json.encode(result),'native-tomahawk-claim-v1',key})
        if not updated or tonumber(updated.affectedRows or updated.affected_rows)~=1 then return refused() end
    end
    spend.phase='claimed'
    local updated=tx.query('UPDATE inventory_grant_receipts SET result_json=? WHERE source_resource=? AND grant_id=?',
        {json.encode(spend),'native-tomahawk-spend-v1',plan.spendReceiptId})
    if not updated or tonumber(updated.affectedRows or updated.affected_rows)~=1 or current()~=true then return refused() end
    return Result.Ok(result)
end
return C
