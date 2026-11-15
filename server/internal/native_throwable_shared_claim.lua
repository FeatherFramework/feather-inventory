-- Transaction primitive. Prompt exports remain guarded by released Weapons
-- authority and disabled until physical throwable units are admitted there.
-- A trusted world-binding writer and released/current collector reservation are
-- prerequisites. This module does not turn native pool reports into authority.
-- Caller must roll back on EVERY failed result or exception.
local C={}
local function copy(v) if type(v)~='table' then return v end;local r={};for k,x in pairs(v) do r[k]=copy(x) end;return r end
local function equal(a,b) return InventoryMetadata.DocumentsEqual(a,b) end
local function int(v,min) return type(v)=='number' and v>=min and v<math.huge and v%1==0 end
local function text(v,max) return type(v)=='string' and #v>0 and #v<=max and not v:find('%c') end
local function callable(v) return type(v)=='function' or (type(v)=='table' and type(rawget(v,'__cfx_functionReference'))=='string') end
local function live(fn)
    if not callable(fn) then return false end
    local ok,value=pcall(fn);return ok and value==true
end
local function wrote(v) return type(v)=='table' and tonumber(v.affectedRows or v.affected_rows)==1 end
local function refused(reason)
    -- Fixed diagnostic labels only: never print a binding, identity or metadata.
    return Result.Err('throwable_shared_claim_refused','Current collector and unclaimed paid world binding required.'
        ..(reason and (' ['..reason..']') or ''))
end
local function worldIdentity(v,claim)
    if type(v)~='table' then return nil end
    if v.version==2 and v.presentation==nil and text(v.projectileInstanceId,64) and int(v.networkId,1)
        and (not claim or v.kind=='physical_throwable_shared_claim') then
        return 'native-tomahawk-physical-binding-v2','projectileInstanceId',v.projectileInstanceId
    end
    local native=v.version==4 and v.presentation=='native'
    local prompt=v.version==3 and (v.presentation==nil or v.presentation=='prompt')
    if not (native or prompt) or not text(v.pickupId,64) or v.projectileInstanceId~=nil or v.networkId~=nil
        or not int(v.pickupRevision,0) or not int(v.bucket,0) or type(v.position)~='table'
        or v.kind~=(native and (claim and 'physical_throwable_native_claim' or 'paid_tomahawk_native_pickup')
            or (claim and 'physical_throwable_prompt_claim' or 'paid_tomahawk_pickup')) then return nil end
    for _,axis in ipairs({'x','y','z'}) do
        local n=v.position[axis]
        if type(n)~='number' or n~=n or n<=-math.huge or n>=math.huge then return nil end
    end
    return native and 'native-tomahawk-native-binding-v4' or 'native-tomahawk-prompt-binding-v3','pickupId',v.pickupId
end
local function decode(value)
    local ok,result=pcall(json.decode,value)
    return ok and type(result)=='table' and result or nil
end
-- Persist a binding supplied by the trusted server world authority. `current`
-- must recheck its exact paid spend/origin and placement reservation; this is
-- NOT a client-authorized writer. Binding itself does not recover an item.
function C.RecordBinding(tx,context,record,current)
    local namespace,idField,worldId=worldIdentity(record,false)
    if type(context)~='table' or context.resource~='feather-weapons' or type(record)~='table'
        or not live(current) or not namespace or record.phase~='available'
        or not text(record.originEventId,64) or not text(record.spendOperationId,40)
        or not int(record.itemId,1) or not int(record.itemRevision,0)
        or type(record.origin)~='table' or type(record.metadata)~='table'
        or not InventoryIdentity.NormalizeCharacterId(context.characterId) then return refused() end
    context,record=copy(context),copy(record)
    for _,key in ipairs({'characterId','sessionId','epoch'}) do
        if not text(context[key],128) or context[key]~=record.origin[key] then return refused() end
    end
    local headers=tx.query('SELECT id FROM inventory WHERE character_id=? LIMIT 1 FOR UPDATE',{context.characterId})
    if type(headers)~='table' or #headers~=1 or not int(tonumber(headers[1].id),1) then return refused() end
    local spends=tx.query('SELECT result FROM feather_ammunition_operations WHERE character_id=? AND operation_id=? FOR UPDATE',
        {context.characterId,'throwable-units:'..record.spendOperationId})
    local spend=spends and #spends==1 and decode(spends[1].result)
    local value,request=spend and spend.value,spend and spend.request
    if not value or value.custody~='spent' or not equal(value.spendIdentity,record.origin)
        or not request or request.action~='spend' or request.operationId~=record.spendOperationId
        or type(value.units)~='table' or #value.units<1 or #value.units>3 then return refused() end
    local paid
    for _,row in ipairs(value.units) do if row.id==record.itemId then
        if paid then return refused() end;paid=row
    end end
    if not paid or paid.revision~=record.itemRevision or not equal(paid.metadata,record.metadata) then return refused() end
    -- Immutable unique aliases prevent a second projectile/origin from being
    -- attached to the same paid item revision, even before anyone collects it.
    local keys={{namespace,worldId},
        {'native-tomahawk-physical-origin-v2',record.originEventId},
        {'native-tomahawk-physical-unit-v2',record.itemId..':'..record.itemRevision}}
    table.sort(keys,function(a,b) return a[1]..'/'..a[2]<b[1]..'/'..b[2] end)
    local existing,empty=0,0
    local historical
    for _,key in ipairs(keys) do
        if not live(current) then return refused() end
        tx.query('INSERT IGNORE INTO inventory_grant_receipts (source_resource,grant_id,request_fingerprint) VALUES (?,?,?)',
            {key[1],key[2],'physical-unit:'..record.itemId..':'..record.itemRevision})
        local rows=tx.query('SELECT result_json FROM inventory_grant_receipts WHERE source_resource=? AND grant_id=? FOR UPDATE',key)
        if type(rows)~='table' or #rows~=1 then return refused() end
        if rows[1].result_json then
            local stored=decode(rows[1].result_json)
            if not stored then return refused() end
            local base=copy(stored);base.phase='available';base.claimPlan=nil;base.claimResult=nil
            if not equal(base,record) or (stored.phase~='available' and stored.phase~='claimed') then return refused() end
            existing=existing+1
            if key[1]==namespace then historical=stored end
        else empty=empty+1 end
    end
    if not live(current) then return refused() end
    if existing==3 then return Result.Ok({binding=copy(historical),replayed=true}) end
    if existing~=0 or empty~=3 then return refused() end
    for _,key in ipairs(keys) do
        local saved=tx.query('UPDATE inventory_grant_receipts SET result_json=? WHERE source_resource=? AND grant_id=?',
            {json.encode(record),key[1],key[2]})
        if not wrote(saved) or not live(current) then return refused() end
    end
    return Result.Ok({binding=copy(record),replayed=false})
end
-- Receipt/status read only. This does not republish a visual, acquire a claim,
-- advance a ledger or turn a caller-supplied pickup ID into authority.
function C.ReadPromptBinding(tx,pickupId)
    if not text(pickupId,64) then return refused() end
    local rows=tx.query('SELECT result_json FROM inventory_grant_receipts WHERE source_resource=? AND grant_id=?',
        {'native-tomahawk-prompt-binding-v3',pickupId})
    local binding=rows and #rows==1 and decode(rows[1].result_json)
    if not binding or not worldIdentity(binding,false) or binding.version~=3 or binding.pickupId~=pickupId
        or (binding.phase~='available' and binding.phase~='claimed') then return refused() end
    return Result.Ok(copy(binding))
end
-- Native collection has a separate receipt namespace and cannot enter the
-- prompt page/feed. No export or live writer is admitted by this primitive.
function C.ReadNativeBinding(tx,pickupId)
    if not text(pickupId,64) then return refused() end
    local rows=tx.query('SELECT result_json FROM inventory_grant_receipts WHERE source_resource=? AND grant_id=?',
        {'native-tomahawk-native-binding-v4',pickupId})
    local binding=rows and #rows==1 and decode(rows[1].result_json)
    if not binding or not worldIdentity(binding,false) or binding.version~=4 or binding.pickupId~=pickupId
        or (binding.phase~='available' and binding.phase~='claimed') then return refused() end
    return Result.Ok(copy(binding))
end
-- Bounded keyset read for durable offer reload, including after resource restart.
-- The caller filters/project public offers; this internal page is not a client API.
function C.ReadPromptPage(tx,afterId)
    if afterId~=nil and not text(afterId,64) then return refused() end
    local rows=tx.query([[SELECT grant_id,result_json FROM inventory_grant_receipts
        WHERE source_resource=? AND grant_id>? ORDER BY grant_id LIMIT 65]],
        {'native-tomahawk-prompt-binding-v3',afterId or ''})
    if type(rows)~='table' or #rows>65 then return refused() end
    local available,cursor={},afterId
    for index=1,math.min(#rows,64) do
        local row=rows[index]
        if type(row)~='table' or not text(row.grant_id,64) or cursor and row.grant_id<=cursor then return refused() end
        local binding=decode(row.result_json)
        if not binding or not worldIdentity(binding,false) or binding.version~=3 or binding.pickupId~=row.grant_id
            or (binding.phase~='available' and binding.phase~='claimed') then return refused() end
        if binding.phase=='available' then available[#available+1]=copy(binding) end
        cursor=row.grant_id
    end
    return Result.Ok({bindings=available,cursor=cursor,hasMore=#rows==65,scanned=math.min(#rows,64)})
end
-- Server caller is authenticated by the export. This returns a confirmed spend
-- row, not a client assertion and not permission to grant or publish a pickup.
function C.ReadSpentUnit(tx,context,operationId,itemId)
    if type(context)~='table' or not InventoryIdentity.NormalizeCharacterId(context.characterId)
        or not text(context.sessionId,128) or not text(context.epoch,128)
        or not text(operationId,40) or not int(itemId,1) then return refused() end
    local rows=tx.query('SELECT result FROM feather_ammunition_operations WHERE character_id=? AND operation_id=?',
        {context.characterId,'throwable-units:'..operationId})
    local receipt=rows and #rows==1 and decode(rows[1].result)
    local request,value=receipt and receipt.request,receipt and receipt.value
    if not request or request.action~='spend' or request.operationId~=operationId
        or not value or value.custody~='spent' or not equal(value.spendIdentity,
            {characterId=context.characterId,sessionId=context.sessionId,epoch=context.epoch})
        or type(value.units)~='table' or #value.units<1 or #value.units>3 then return refused() end
    local found
    for _,row in ipairs(value.units) do if row.id==itemId then
        if found or not int(row.revision,0) or type(row.metadata)~='table' then return refused() end
        found=row
    end end
    if not found then return refused() end
    return Result.Ok({custody='spent',operationId=operationId,itemId=found.id,itemRevision=found.revision,
        metadata=copy(found.metadata),origin=copy(value.spendIdentity)})
end
function C.Apply(tx,context,plan,limits,current)
    local namespace,idField,worldId=worldIdentity(plan,true)
    if type(context)~='table' or type(plan)~='table' or not live(current)
        or context.resource~='feather-weapons' or not namespace
        or not text(plan.originEventId,64)
        or not text(plan.spendOperationId,40)
        or not int(plan.itemId,1) or not int(plan.itemRevision,0) or type(plan.metadata)~='table'
        or not int(plan.expectedRevision,0) or type(plan.expectedPools)~='table'
        or type(limits)~='table' or limits.ammo_tomahawk_regular~=3
        or type(plan.origin)~='table' or type(plan.collector)~='table' then return refused() end
    context,plan,limits=copy(context),copy(plan),copy(limits)
    for _,identity in ipairs({plan.origin,plan.collector}) do
        if not InventoryIdentity.NormalizeCharacterId(identity.characterId) then return refused() end
        for _,key in ipairs({'sessionId','epoch'}) do if not text(identity[key],128) then return refused() end end
    end
    for _,key in ipairs({'characterId','sessionId','epoch'}) do
        if context[key]~=plan.collector[key] then return refused() end
    end
    -- Same order for A->B and B->A. Donor need not still have an active login.
    -- Spend already removed its ammunition; this transaction never rewrites it.
    local characters={plan.origin.characterId}
    if context.characterId~=characters[1] then characters[2]=context.characterId end
    table.sort(characters)
    local headers={}
    for _,id in ipairs(characters) do
        local rows=tx.query('SELECT id FROM inventory WHERE character_id=? LIMIT 1 FOR UPDATE',{id})
        if type(rows)~='table' or #rows~=1 or not int(tonumber(rows[1].id),1) then return refused() end
        headers[id]=tonumber(rows[1].id)
    end
    if not live(current) then return refused() end
    local ledger=CharacterAmmunitionAPI.ReadSnapshot(tx,context.characterId,limits,false)
    if not ledger or not ledger.ok then return ledger or refused() end
    local records=tx.query('SELECT result_json FROM inventory_grant_receipts WHERE source_resource=? AND grant_id=? FOR UPDATE',
        {namespace,worldId})
    local binding=records and #records==1 and decode(records[1].result_json)
    -- Preserve the original short-circuit order, including the yielding authority
    -- call. A refusal must identify the failed predicate without changing it.
    if not binding then return refused('binding_missing') end
    if binding.version~=plan.version then return refused('binding_version_changed') end
    if binding[idField]~=worldId then return refused('binding_id_changed') end
    if plan.version==3 or plan.version==4 then
        if not worldIdentity(binding,false) then return refused('binding_shape_changed') end
        if binding.pickupRevision~=plan.pickupRevision then return refused('binding_revision_changed') end
        if binding.bucket~=plan.bucket then return refused('binding_bucket_changed') end
        if not equal(binding.position,plan.position) then return refused('binding_position_changed') end
    end
    if binding.originEventId~=plan.originEventId then return refused('binding_event_changed') end
    if binding.networkId~=plan.networkId then return refused('binding_network_changed') end
    if binding.spendOperationId~=plan.spendOperationId then return refused('binding_spend_changed') end
    if not equal(binding.origin,plan.origin) then return refused('binding_origin_changed') end
    if binding.itemId~=plan.itemId then return refused('binding_item_changed') end
    if binding.itemRevision~=plan.itemRevision then return refused('binding_item_revision_changed') end
    if not equal(binding.metadata,plan.metadata) then return refused('binding_metadata_changed') end
    if not live(current) then return refused('binding_authority_changed') end
    if binding.phase=='claimed' then
        local expectedPools=copy(plan.expectedPools)
        if not int(expectedPools.ammo_tomahawk_regular,0) or expectedPools.ammo_tomahawk_regular>=3 then return refused() end
        expectedPools.ammo_tomahawk_regular=expectedPools.ammo_tomahawk_regular+1
        if not equal(binding.claimPlan,plan) or type(binding.claimResult)~='table'
            or binding.claimResult.characterId~=context.characterId or binding.claimResult.itemId~=plan.itemId
            or binding.claimResult.revision~=plan.expectedRevision+1
            or binding.claimResult.itemRevision~=plan.itemRevision+1
            or binding.claimResult[idField]~=worldId
            or not equal(binding.claimResult.pools,expectedPools)
            or not equal(binding.claimResult.origin,plan.origin)
            or not equal(binding.claimResult.collector,plan.collector) then return refused() end
        local result=copy(binding.claimResult);result.replayed=true
        return Result.Ok(result) -- historical readback; no item or ledger replay
    end
    if binding.phase~='available' then return refused('binding_not_available') end
    if ledger.value.revision~=plan.expectedRevision then return refused('collector_revision_changed') end
    if not equal(ledger.value.pools,plan.expectedPools) then return refused('collector_pools_changed') end
    local spends=tx.query('SELECT result FROM feather_ammunition_operations WHERE character_id=? AND operation_id=? FOR UPDATE',
        {plan.origin.characterId,'throwable-units:'..plan.spendOperationId})
    local spend=spends and #spends==1 and decode(spends[1].result)
    local request,value=spend and spend.request,spend and spend.value
    if not request or request.action~='spend' or request.operationId~=plan.spendOperationId
        or not value or value.custody~='spent' or not equal(value.spendIdentity,plan.origin)
        or type(value.units)~='table' or #value.units<1 or #value.units>3 then return refused() end
    local paid
    for _,row in ipairs(value.units) do if row.id==plan.itemId then
        if paid then return refused() end;paid=row
    end end
    if not paid or paid.revision~=plan.itemRevision or not equal(paid.metadata,plan.metadata) then return refused() end
    local sourceRows=tx.query([[SELECT i.id,i.location,i.character_id,i.owner_character_id,i.is_public,i.max_slots
        FROM inventory_character_collections c INNER JOIN inventory i ON i.id=c.inventory_id
        WHERE c.source_resource=? AND c.collection_key=? AND c.character_id=? FOR UPDATE]],
        {'feather-weapons','native_throwable_spent_v1',plan.origin.characterId})
    local source=sourceRows and #sourceRows==1 and sourceRows[1]
    if not source or not int(tonumber(source.id),1) or source.location~='character_collection'
        or source.character_id~=nil or source.owner_character_id~=nil or tonumber(source.is_public)~=0
        or tonumber(source.max_slots)~=500 then return refused() end
    local itemRows=tx.query([[SELECT ii.id,ii.inventory_id,ii.row_revision,ii.metadata,
        d.name AS itemName,d.type,d.instance_mode,d.archived_at FROM inventory_items ii
        INNER JOIN items d ON d.id=ii.item_id WHERE ii.id=? FOR UPDATE]],{plan.itemId})
    local item=itemRows and #itemRows==1 and itemRows[1]
    local metadata=item and (type(item.metadata)=='table' and item.metadata or decode(item.metadata))
    if not item or tonumber(item.inventory_id)~=tonumber(source.id) or tonumber(item.row_revision)~=plan.itemRevision
        or item.itemName~='weapon_thrown_tomahawk' or item.type~='item_weapon' or item.instance_mode~='unique'
        or item.archived_at~=nil or not equal(metadata,plan.metadata)
        or metadata.weaponDefinitionId~='throwable_tomahawk' or metadata.schemaVersion~=2
        or not text(metadata.serialNumber,128) or type(metadata.flags)~='table'
        or metadata.flags.disabled~=false or metadata.flags.evidence~=false then return refused() end
    local bound=tx.query('SELECT slot FROM character_equipment WHERE inventory_items_id=? FOR UPDATE',{plan.itemId})
    if type(bound)~='table' or #bound~=0 then return refused() end
    local denied=tx:RequireAccess(headers[context.characterId],InventoryAPI.AccessModes.INSERT)
    if denied then return denied end
    local accepted=InventoryControllers.AcceptanceInTransaction(tx.query,headers[context.characterId],
        {{item='weapon_thrown_tomahawk',quantity=1}})
    if accepted~=true or not live(current) then return refused() end
    local read=NativeThrowableUnitStorage.Read(tx,context,limits,current)
    if not read or not read.ok then return read or refused() end
    if #read.value.units>=3 or not equal(read.value.pools,plan.expectedPools)
        or read.value.revision~=plan.expectedRevision then return refused() end
    for _,row in ipairs(read.value.units) do
        if row.id==plan.itemId or row.metadata.serialNumber==metadata.serialNumber then return refused() end
    end
    local destination=CharacterCollectionAPI.Resolve(tx,{resource='feather-weapons',key='native_throwable_units_v1',
        characterId=context.characterId,maxItems=3})
    if not destination or not destination.ok then return destination or refused() end
    local to=destination.value.id
    if not int(to,1) or to==tonumber(source.id) or to==headers[context.characterId] then return refused() end
    local occupied=tx.query('SELECT slot_index FROM inventory_items WHERE inventory_id=? ORDER BY id FOR UPDATE',{to})
    if type(occupied)~='table' or #occupied~=#read.value.units then return refused() end
    local used={}
    for _,row in ipairs(occupied) do
        local slot=tonumber(row.slot_index)
        if not int(slot,0) or slot>2 or used[slot] then return refused() end;used[slot]=true
    end
    local slot=0;while used[slot] do slot=slot+1 end
    if slot>2 or not live(current) then return refused() end
    local moved=tx:MoveInstance(plan.itemId,to,slot)
    if not moved or not moved.ok then return moved or refused() end
    local check=tx.query('SELECT inventory_id,row_revision FROM inventory_items WHERE id=? FOR UPDATE',{plan.itemId})
    if type(check)~='table' or #check~=1 or tonumber(check[1].inventory_id)~=to
        or tonumber(check[1].row_revision)~=plan.itemRevision+1 then return refused() end
    -- Private-to-private movement must not publish a misleading nil->nil owner
    -- fact. The durable claim records explicit origin and collector identities.
    local fact=tx.moved and tx.moved[#tx.moved]
    if not fact or fact.instanceId~=plan.itemId or fact.fromInventoryId~=tonumber(source.id)
        or fact.toInventoryId~=to or fact.revision~=plan.itemRevision+1 then return refused() end
    table.remove(tx.moved)
    local pools=copy(plan.expectedPools)
    if not int(pools.ammo_tomahawk_regular,0) or pools.ammo_tomahawk_regular>=3 then return refused() end
    pools.ammo_tomahawk_regular=pools.ammo_tomahawk_regular+1
    if not live(current) then return refused() end
    local updated=tx.query('UPDATE feather_character_ammunition SET pools=?,revision=? WHERE character_id=? AND revision=?',
        {json.encode(pools),plan.expectedRevision+1,context.characterId,plan.expectedRevision})
    if not wrote(updated) then return refused() end
    local snapshot=NativeThrowableUnitStorage.Read(tx,context,limits,current)
    if not snapshot or not snapshot.ok then return snapshot or refused() end
    local result={characterId=context.characterId,revision=plan.expectedRevision+1,pools=pools,
        itemId=plan.itemId,itemRevision=plan.itemRevision+1,[idField]=worldId,
        origin=copy(plan.origin),collector=copy(plan.collector),throwableUnitsSnapshot=snapshot.value,
        looseInventoryDelta=0,nativeAmmoDelta=0,replayed=false}
    binding.phase='claimed';binding.claimPlan=copy(plan);binding.claimResult=copy(result)
    updated=tx.query('UPDATE inventory_grant_receipts SET result_json=? WHERE source_resource=? AND grant_id=?',
        {json.encode(binding),namespace,worldId})
    if not wrote(updated) or not live(current) then return refused() end
    return Result.Ok(result)
end
NativeThrowableSharedClaim=C
return C
