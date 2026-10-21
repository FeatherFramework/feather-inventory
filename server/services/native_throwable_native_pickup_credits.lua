-- Server-only durable bounded native-pickup spend evidence. No pickup route.
-- Called inside the same transaction as a reserved active ammo observation.
NativeThrowableNativePickupCredits={}
local C=NativeThrowableNativePickupCredits
local namespace='native-tomahawk-native-spend-v1'
local function copy(v) if type(v)~='table' then return v end; local r={}; for k,x in pairs(v) do r[k]=copy(x) end; return r end
local function equal(a,b)
    if type(a)~=type(b) then return false end; if type(a)~='table' then return a==b end
    for k,v in pairs(a) do if not equal(v,b[k]) then return false end end
    for k in pairs(b) do if a[k]==nil then return false end end; return true
end
local function int(v,min) return type(v)=='number' and v>=min and v<math.huge and v%1==0 end
local function text(v,max) return type(v)=='string' and #v>0 and #v<=max and not v:find('%c') end
local function callable(v) return type(v)=='function' or (type(v)=='table' and type(rawget(v,'__cfx_functionReference'))=='string') end
local function refused() return Result.Err('native_pickup_spend_refused','Exact reserved active consumption required.') end
function C.Record(tx,context,before,after,limits,current)
    if not callable(current) or current()~=true or type(context)~='table' or type(before)~='table'
        or type(after)~='table' or not int(before.revision,0) or after.revision~=before.revision+1
        or type(limits)~='table' or limits.ammo_tomahawk_regular~=1
        or type(before.pools)~='table' or type(after.pools)~='table'
        or before.pools.ammo_tomahawk_regular~=1 or after.pools.ammo_tomahawk_regular~=0 then return refused() end
    context,before,after,limits=copy(context),copy(before),copy(after),copy(limits)
    local identity={characterId=context.characterId,sessionId=context.sessionId,epoch=context.runtimeEpoch}
    for _,v in pairs(identity) do if not text(v,128) then return refused() end end
    if not text(identity.characterId,128) or not text(identity.sessionId,128) or not text(identity.epoch,128) then return refused() end
    for id,limit in pairs(limits) do
        if not int(limit,0) or not int(before.pools[id],0) or not int(after.pools[id],0)
            or before.pools[id]>limit or after.pools[id]>before.pools[id] then return refused() end
    end
    for id in pairs(before.pools) do if limits[id]==nil then return refused() end end
    for id in pairs(after.pools) do if limits[id]==nil then return refused() end end
    -- Independently verify the after-ledger is locked and already written by
    -- this observation; recording alone must never create consumption credit.
    local locked=CharacterAmmunitionAPI.ReadSnapshot(tx,context.characterId,limits,false)
    if not locked or not locked.ok or locked.value.revision~=after.revision
        or not equal(locked.value.pools,after.pools) or current()~=true then return refused() end
    local read=NativeThrowableEquipment.Read(tx,context.characterId,nil,current)
    local value=read and read.ok and read.value
    local row=value and value.equipment and value.equipment.throwable
    local expected=value and value.expected and value.expected.weapon_throwable
    if not row or not int(row.id,1) or not int(row.revision,0) or not expected
        or expected.itemId~=row.id or expected.revision~=row.revision or type(row.metadata)~='table'
        or not text(row.metadata.serialNumber,128) or current()~=true then return refused() end
    local receiptId=('spend:%s:%s'):format(row.id,after.revision)
    if #receiptId>64 then return refused() end
    local key={characterId=identity.characterId,sessionId=identity.sessionId,epoch=identity.epoch,
        revisionBefore=before.revision,revisionAfter=after.revision,ammunitionId='ammo_tomahawk_regular'}
    local candidate={version=1,kind='unbound_spend_candidate',identity=copy(identity),key=key,
        itemId=row.id,itemRevision=row.revision,serialNumber=row.metadata.serialNumber,
        definitionId='throwable_tomahawk',units=1,pickupCredits=false,requiresProjectileBinding=true,
        requiresDurableSingleClaim=true}
    before.characterId=identity.characterId; before.sessionId=identity.sessionId; before.epoch=identity.epoch; before.phase='active'
    after.characterId=identity.characterId; after.sessionId=identity.sessionId; after.epoch=identity.epoch; after.phase='active'
    local record={policy='same_session_native_spend_credit_v1',phase='committed_unclaimed',receiptId=receiptId,
        candidate=candidate,before=before,after=after,snapshot={characterId=identity.characterId,
            revision=before.revision,pools=copy(before.pools),expected=copy(value.expected),equipment=copy(value.equipment)}}
    local fingerprint='native-spend-v1:'..identity.characterId..':'..identity.sessionId..':'..identity.epoch..':'..receiptId
    if #fingerprint>300 then return refused() end
    tx.query('INSERT IGNORE INTO inventory_grant_receipts (source_resource,grant_id,request_fingerprint) VALUES (?,?,?)',
        {namespace,receiptId,fingerprint})
    local rows=tx.query('SELECT request_fingerprint,result_json FROM inventory_grant_receipts WHERE source_resource=? AND grant_id=? FOR UPDATE',
        {namespace,receiptId})
    local stored=rows and rows[1]
    if not stored or stored.request_fingerprint~=fingerprint or current()~=true then return refused() end
    if stored.result_json then
        local ok,existing=pcall(json.decode,stored.result_json)
        if not ok or not equal(existing,record) then return refused() end
        return Result.Ok({spendReceiptId=receiptId,replayed=true,credit=copy(record)})
    end
    local updated=tx.query('UPDATE inventory_grant_receipts SET result_json=? WHERE source_resource=? AND grant_id=?',
        {json.encode(record),namespace,receiptId})
    if not updated or tonumber(updated.affectedRows or updated.affected_rows)~=1 or current()~=true then return refused() end
    return Result.Ok({spendReceiptId=receiptId,replayed=false,credit=copy(record)})
end
