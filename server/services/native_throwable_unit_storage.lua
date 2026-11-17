-- Staged internal transaction component. No export, command, startup mutation,
-- or gameplay caller. The normal throwable flow must compose release/wear,
-- carrying weight and native restoration before exposing this component.
NativeThrowableUnitStorage={}
local U=NativeThrowableUnitStorage
local function copy(v)
    if type(v)~='table' then return v end
    local out={};for k,x in pairs(v) do out[k]=copy(x) end;return out
end
local function int(v,min) return type(v)=='number' and v>=min and v%1==0 and v<math.huge end
local function callable(v)
    return type(v)=='function' or (type(v)=='table' and type(rawget(v,'__cfx_functionReference'))=='string')
end
local function refused() return Result.Err('throwable_unit_storage_refused','Throwable unit snapshot or authority changed.') end
local function current(fn)
    if not callable(fn) then return false end
    local ok,value=pcall(fn);return ok and value==true
end
local function affected(result) return type(result)=='table' and tonumber(result.affectedRows)==1 end
local function metadata(row)
    local ok,value=pcall(function() return type(row.metadata)=='table' and row.metadata or json.decode(row.metadata) end)
    if not ok or type(value)~='table' or value.schemaVersion~=2
        or value.weaponDefinitionId~='throwable_tomahawk' or type(value.serialNumber)~='string'
        or #value.serialNumber<1 or #value.serialNumber>128 or value.serialNumber:find('%c')
        or type(value.condition)~='number' or value.condition<1 or value.condition>100
        or value.condition~=value.condition or type(value.flags)~='table'
        or value.flags.disabled~=false or value.flags.evidence~=false
        or type(value.flags.stolen)~='boolean'
        or value.maintenance~=nil or type(value.ammo)~='table'
        or value.ammo.ownership~='character' or value.ammo.type~='ammo_tomahawk_regular'
        or row.itemName~='weapon_thrown_tomahawk' or row.type~='item_weapon'
        or row.instance_mode~='unique' or row.archived_at~=nil then return nil end
    return value
end
-- Indexed character -> purpose -> private inventory lookup. Includes carried
-- units even while gameplay admission is disabled; a switch cannot shed weight.
-- Spent storage is deliberately excluded. Returned rows never occupy public slots.
function U.Accounting(query,inventoryId,lock)
    -- Collection tables may inherit a different collation than the base
    -- inventory table. Resolve the UUID first, then use a bound value against
    -- the collection index instead of comparing differently collated columns.
    local source=query('SELECT character_id FROM inventory WHERE id=?'..(lock and ' FOR UPDATE' or ''),{inventoryId})
    if type(source)~='table' or #source~=1 then return nil end
    local character=source[1].character_id
    if character==nil then return {weight=0,counts={},rows={}} end
    if type(character)~='string' or #character==0 then return nil end
    local rows=query([[SELECT held.id,held.item_id,held.row_revision,held.metadata,
        d.name AS itemName,d.type,d.instance_mode,d.archived_at,d.weight,
        storage.id AS custody_id,storage.location,storage.character_id,
        storage.owner_character_id,storage.is_public,storage.max_slots
        FROM inventory_character_collections c
        INNER JOIN inventory storage ON storage.id=c.inventory_id
        LEFT JOIN inventory_items held ON held.inventory_id=storage.id
        LEFT JOIN items d ON d.id=held.item_id
        WHERE c.source_resource='feather-weapons' AND c.collection_key='native_throwable_units_v1'
          AND c.character_id=? ORDER BY held.id]]..(lock and ' FOR UPDATE' or ''),{character})
    if type(rows)~='table' or #rows>3 then return nil end
    local result={weight=0,counts={},rows={}}
    local seen={}
    for _,row in ipairs(rows) do
        if row.location~='character_collection' or row.character_id~=nil or row.owner_character_id~=nil
            or tonumber(row.is_public)~=0 or tonumber(row.max_slots)~=3
            or not int(tonumber(row.custody_id),1) or tonumber(row.custody_id)==inventoryId then return nil end
        if row.id~=nil then
            local id,definition,weight=tonumber(row.id),tonumber(row.item_id),tonumber(row.weight)
            if not int(id,1) or seen[id] or not int(definition,1) or not weight
                or weight<0 or weight~=weight or weight==math.huge
                or row.itemName~='weapon_thrown_tomahawk' or row.type~='item_weapon'
                or row.instance_mode~='unique' then return nil end
            seen[id]=true;result.weight=result.weight+weight
            local key=tostring(definition);result.counts[key]=(result.counts[key] or 0)+1
            local held=copy(row);held.slot_index=nil;held.weight=weight
            result.rows[#result.rows+1]=held
        end
    end
    return result
end
-- Read-only production-shaped custody snapshot. No collection is created by a
-- read; fresh/empty characters return no units. No export/admission yet.
function U.Read(tx,context,limits,authority)
    if type(context)~='table' or type(limits)~='table' or limits.ammo_tomahawk_regular~=3
        or not InventoryIdentity.NormalizeCharacterId(context.characterId) or not current(authority) then return refused() end
    for _,key in ipairs({'sessionId','epoch'}) do
        if type(context[key])~='string' or #context[key]<1 or #context[key]>128 or context[key]:find('%c') then return refused() end
    end
    context,limits=copy(context),copy(limits)
    local header=tx.query('SELECT id FROM inventory WHERE character_id=? LIMIT 1 FOR UPDATE',{context.characterId})
    if type(header)~='table' or #header~=1 or not int(tonumber(header[1].id),1) then return refused() end
    local ledger=CharacterAmmunitionAPI.ReadSnapshot(tx,context.characterId,limits,false)
    if not ledger or not ledger.ok then return ledger or refused() end
    local held=U.Accounting(tx.query,tonumber(header[1].id),true)
    if not held or #held.rows~=ledger.value.pools.ammo_tomahawk_regular or not current(authority) then return refused() end
    local units,serials={},{}
    for _,row in ipairs(held.rows) do
        local document=metadata(row)
        if not document or serials[document.serialNumber] or not int(tonumber(row.row_revision),0) then return refused() end
        serials[document.serialNumber]=true
        units[#units+1]={id=tonumber(row.id),revision=tonumber(row.row_revision),itemName=row.itemName,metadata=copy(document)}
    end
    return Result.Ok({contract=2,kind='physical_throwable_units',characterId=context.characterId,
        identity={characterId=context.characterId,sessionId=context.sessionId,epoch=context.epoch},
        revision=ledger.value.revision,pools=copy(ledger.value.pools),units=units})
end
-- Caller owns the enclosing Inventory transaction and must roll it back on any
-- failed result. Units are moved, never copied or granted. Header -> ledger ->
-- receipt -> private header/items is the common serialized order.
function U.Apply(tx,context,spec,authority)
    if type(context)~='table' or type(spec)~='table' or not current(authority) then return refused() end
    context,spec=copy(context),copy(spec)
    local characterId=InventoryIdentity.NormalizeCharacterId(context.characterId)
    if spec.action=='spend' then
        for _,key in ipairs({'sessionId','epoch'}) do
            if type(context[key])~='string' or #context[key]<1 or #context[key]>128
                or context[key]:find('%c') then return refused() end
        end
    end
    if not characterId or spec.version~=1 or (spec.action~='carry' and spec.action~='return' and spec.action~='spend')
        or type(spec.operationId)~='string' or not spec.operationId:match('^[%w._:%-]+$')
        or #spec.operationId>40 or not int(spec.expectedRevision,0)
        or type(spec.expectedPools)~='table' or type(spec.limits)~='table'
        or spec.limits.ammo_tomahawk_regular~=3 or type(spec.items)~='table'
        or #spec.items<1 or #spec.items>3 then return refused() end
    local ids,ordered={},{}
    for key,item in pairs(spec.items) do
        if not int(key,1) or key>#spec.items or type(item)~='table'
            or not int(item.id,1) or not int(item.revision,0) or type(item.metadata)~='table'
            or ids[item.id] then return refused() end
        ids[item.id]=true;ordered[#ordered+1]=item
    end
    table.sort(ordered,function(a,b) return a.id<b.id end)
    local headers=tx.query('SELECT id, max_slots FROM inventory WHERE character_id=? LIMIT 1 FOR UPDATE',{characterId})
    local header=headers and headers[1]
    if not header or not int(tonumber(header.id),1) then return refused() end
    local inventoryId=tonumber(header.id)
    local ledger=CharacterAmmunitionAPI.ReadSnapshot(tx,characterId,spec.limits,false)
    if not ledger or not ledger.ok or not current(authority) then return refused() end
    local operationId='throwable-units:'..spec.operationId
    local receipts=tx.query('SELECT result FROM feather_ammunition_operations WHERE character_id=? AND operation_id=? FOR UPDATE',
        {characterId,operationId})
    if receipts and receipts[1] then
        local ok,receipt=pcall(json.decode,receipts[1].result)
        if not ok or type(receipt)~='table' or not InventoryMetadata.DocumentsEqual(receipt.request,spec)
            or type(receipt.value)~='table' or not current(authority) then return refused() end
        if spec.action=='spend' and not InventoryMetadata.DocumentsEqual(receipt.value.spendIdentity,
            {characterId=characterId,sessionId=context.sessionId,epoch=context.epoch}) then return refused() end
        local value=copy(receipt.value);value.replayed=true
        return Result.Ok(value) -- readback only, even if the live ledger has advanced
    end
    if ledger.value.revision~=spec.expectedRevision
        or not InventoryMetadata.DocumentsEqual(ledger.value.pools,spec.expectedPools) then return refused() end
    local resolved=CharacterCollectionAPI.Resolve(tx,{resource='feather-weapons',key='native_throwable_units_v1',
        characterId=characterId,maxItems=3})
    if not resolved or not resolved.ok then return resolved or refused() end
    local privateId=resolved.value.id
    if not int(privateId,1) or privateId==inventoryId then return refused() end
    local held=tx.query([[SELECT ii.id,ii.row_revision,ii.slot_index,ii.metadata,i.name AS itemName,
        i.type,i.instance_mode,i.archived_at FROM inventory_items ii INNER JOIN items i ON i.id=ii.item_id
        WHERE ii.inventory_id=? ORDER BY ii.id FOR UPDATE]],{privateId})
    if type(held)~='table' or #held>3 or #held~=ledger.value.pools.ammo_tomahawk_regular then return refused() end
    local used,heldIds,serials={},{},{}
    for _,row in ipairs(held) do
        local slot,id=tonumber(row.slot_index),tonumber(row.id)
        local document=metadata(row)
        if not int(slot,0) or slot>2 or used[slot] or not int(id,1) or heldIds[id]
            or not int(tonumber(row.row_revision),0) or not document or serials[document.serialNumber] then return refused() end
        used[slot]=true;heldIds[id]=true;serials[document.serialNumber]=true
    end
    local quantity=#ordered
    local delta=spec.action=='carry' and quantity or -quantity
    local after=#held+delta
    if after<0 or after>3 then return refused() end
    local from=spec.action=='carry' and inventoryId or privateId
    local to=spec.action=='carry' and privateId or inventoryId
    local denied=tx:RequireAccess(inventoryId,spec.action=='return' and InventoryAPI.AccessModes.INSERT or InventoryAPI.AccessModes.REMOVE)
    if denied then return denied end
    local rows,selectedSerials={},{}
    for _,expected in ipairs(ordered) do
        local found=tx.query([[SELECT ii.id,ii.row_revision,ii.metadata,i.name AS itemName,i.type,i.instance_mode,i.archived_at
            FROM inventory_items ii INNER JOIN items i ON i.id=ii.item_id
            WHERE ii.id=? AND ii.inventory_id=? FOR UPDATE]],{expected.id,from})
        local row=found and #found==1 and found[1]
        local document=row and metadata(row)
        if not row or tonumber(row.id)~=expected.id or tonumber(row.row_revision)~=expected.revision
            or not document or not InventoryMetadata.DocumentsEqual(document,expected.metadata) then return refused() end
        if selectedSerials[document.serialNumber] or (spec.action=='carry' and serials[document.serialNumber]) then return refused() end
        selectedSerials[document.serialNumber]=true
        -- New unit storage cannot silently detach an old carrier or an equipped
        -- melee/firearm. Its released-owner adapter must remove bindings first.
        local bound=tx.query('SELECT slot FROM character_equipment WHERE inventory_items_id=? FOR UPDATE',{expected.id})
        if type(bound)~='table' or #bound~=0 then return refused() end
        rows[#rows+1]={id=expected.id,revision=expected.revision,metadata=document}
    end
    if spec.action=='return' then
        local accepted=InventoryControllers.AcceptanceInTransaction(tx.query,inventoryId,
            {{item='weapon_thrown_tomahawk',quantity=quantity}},ids)
        if accepted~=true then return refused() end
        local occupied=tx.query('SELECT slot_index FROM inventory_items WHERE inventory_id=? ORDER BY id FOR UPDATE',{inventoryId})
        if type(occupied)~='table' then return refused() end
        used={}
        for _,row in ipairs(occupied or {}) do
            local slot=tonumber(row.slot_index);if slot then used[slot]=true end
        end
    end
    -- NULL max_slots means the configured ordinary Inventory capacity. Match
    -- GetInventoryCapacity without opening a separate DB connection here.
    -- An explicit zero stays zero and is refused below; it is not a fallback.
    local maximum=spec.action=='carry' and 3 or (tonumber(header.max_slots) or tonumber(Config.maxItemSlots) or 0)
    if spec.action=='spend' then
        -- Retain the same physical instance pending eventual verified recovery
        -- or a separately reviewed retirement policy. Never return it merely
        -- because a native pool increased. Storage is bounded, not unbounded.
        local spent=CharacterCollectionAPI.Resolve(tx,{resource='feather-weapons',key='native_throwable_spent_v1',
            characterId=characterId,maxItems=500})
        if not spent or not spent.ok then return spent or refused() end
        to=spent.value.id;maximum=500
        if not int(to,1) or to==inventoryId or to==privateId then return refused() end
        local occupied=tx.query('SELECT slot_index FROM inventory_items WHERE inventory_id=? ORDER BY id FOR UPDATE',{to})
        if type(occupied)~='table' or #occupied+quantity>maximum then return refused() end
        used={}
        for _,row in ipairs(occupied) do
            local slot=tonumber(row.slot_index)
            if not int(slot,0) or slot>=maximum or used[slot] then return refused() end
            used[slot]=true
        end
    end
    if not int(maximum,1) then return refused() end
    for _,row in ipairs(rows) do
        local slot=0;while used[slot] and slot<maximum do slot=slot+1 end
        if slot>=maximum or not current(authority) then return refused() end
        local moved=tx:MoveInstance(row.id,to,slot)
        if not moved or not moved.ok then return moved or refused() end
        local check=tx.query('SELECT inventory_id,row_revision FROM inventory_items WHERE id=? FOR UPDATE',{row.id})
        if type(check)~='table' or #check~=1 or tonumber(check[1].inventory_id)~=to
            or tonumber(check[1].row_revision)~=row.revision+1 then return refused() end
        -- Internal custody is not a deposit/pickup or ownership transfer. Keep
        -- it in this operation's durable receipt; do not emit the generic
        -- ItemMoved fact that would publish a false ownership transition while
        -- an observation still holds the native lease.
        local pending=tx.moved and tx.moved[#tx.moved]
        if not pending or pending.instanceId~=row.id or pending.fromInventoryId~=from
            or pending.toInventoryId~=to or pending.revision~=row.revision+1 then return refused() end
        table.remove(tx.moved)
        used[slot]=true;row.revision=row.revision+1
    end
    local pools=copy(ledger.value.pools);pools.ammo_tomahawk_regular=after
    if spec.observedPools~=nil then
        if spec.action~='spend' or type(spec.observedPools)~='table'
            or spec.observedPools.ammo_tomahawk_regular~=after then return refused() end
        for id,amount in pairs(pools) do
            local observed=spec.observedPools[id]
            if not int(observed,0) or observed>amount then return refused() end
        end
        for id in pairs(spec.observedPools) do if pools[id]==nil then return refused() end end
        pools=copy(spec.observedPools)
    end
    if not current(authority) then return refused() end
    local updated=tx.query('UPDATE feather_character_ammunition SET pools=?,revision=? WHERE character_id=? AND revision=?',
        {json.encode(pools),spec.expectedRevision+1,characterId,spec.expectedRevision})
    if not affected(updated) then return refused() end
    local value={characterId=characterId,revision=spec.expectedRevision+1,pools=pools,units=rows,
        inventoryDelta=spec.action=='spend' and 0 or -delta,operationId=spec.operationId,
        custody=spec.action=='spend' and 'spent' or (spec.action=='carry' and 'carried' or 'inventory'),replayed=false}
    if spec.action=='spend' then
        -- Durable origin identity accompanies the actual post-move paid rows.
        -- This is funded-spend evidence, not world-projectile origin proof.
        value.spendIdentity={characterId=characterId,sessionId=context.sessionId,epoch=context.epoch}
    end
    if spec.observedPools then
        local read=U.Read(tx,context,spec.limits,authority)
        if not read or not read.ok then return read or refused() end
        value.throwableUnitsSnapshot=read.value
    end
    local written=tx.query('INSERT INTO feather_ammunition_operations (character_id,operation_id,result) VALUES (?,?,?)',
        {characterId,operationId,json.encode({request=spec,value=value})})
    if not affected(written) or not current(authority) then return refused() end
    return Result.Ok(value)
end

-- Trusted observation composition only. Keep the lowest stable IDs carried so
-- partial depletion does not needlessly change the single native GUID anchor.
function U.Observe(tx,context,spec,authority)
    if type(context)~='table' or type(spec)~='table' or not current(authority) then return refused() end
    context,spec=copy(context),copy(spec);context.epoch=context.runtimeEpoch
    local read=U.Read(tx,context,spec.limits,authority)
    if not read or not read.ok then return read or refused() end
    local snapshot=read.value
    if snapshot.revision~=spec.expectedRevision or type(spec.pools)~='table' then return refused() end
    local after=spec.pools.ammo_tomahawk_regular
    local before=snapshot.pools.ammo_tomahawk_regular
    if not int(after,0) or after>=before then return refused() end
    local items={}
    for index=after+1,before do
        local row=snapshot.units[index]
        items[#items+1]={id=row.id,revision=row.revision,metadata=copy(row.metadata)}
    end
    return U.Apply(tx,context,{version=1,action='spend',operationId='observe:'..spec.expectedRevision,
        expectedRevision=spec.expectedRevision,expectedPools=copy(snapshot.pools),limits=copy(spec.limits),
        observedPools=copy(spec.pools),items=items},authority)
end
