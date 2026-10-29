-- Private character-owned collections. Only the configured owning resource can
-- access them; clients cannot open them as ordinary/robbery/shared inventories.
CharacterCollectionAPI={}
local C=CharacterCollectionAPI
local function bad(code,message) return Result.Err(code or 'collection_unavailable',message or 'Character collection is unavailable.') end
local function policy(request,resource)
    local scopes=Config.TrustedCharacterCollections and Config.TrustedCharacterCollections[resource or '']
    local p=type(request)=='table' and scopes and scopes[request.collectionKey]
    if type(p)~='table' or type(p.items)~='table' then return bad('authorization_denied','Collection caller/purpose is not trusted.') end
    local character=InventoryIdentity.NormalizeCharacterId(request.characterId)
    if not character then return bad('invalid_input','Character UUID required.') end
    return Result.Ok({characterId=character,resource=resource,key=request.collectionKey,items=p.items,
        marker=p.marker,maxItems=math.floor(math.max(1,math.min(500,tonumber(p.maxItems) or 500)))})
end
C.Validate=policy
function C.Start()
    DB.exec([[CREATE TABLE IF NOT EXISTS inventory_character_collections (
        source_resource VARCHAR(100) NOT NULL, collection_key VARCHAR(100) NOT NULL,
        character_id CHAR(36) NOT NULL, inventory_id BIGINT UNSIGNED NOT NULL,
        PRIMARY KEY(source_resource,collection_key,character_id), UNIQUE KEY collection_inventory(inventory_id)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]])
    DB.exec([[CREATE TABLE IF NOT EXISTS inventory_collection_retirements (
        source_resource VARCHAR(100) NOT NULL,operation_id VARCHAR(128) NOT NULL,
        request_json LONGTEXT NOT NULL,result_json LONGTEXT NULL,
        PRIMARY KEY(source_resource,operation_id)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]])
    DB.exec([[CREATE TABLE IF NOT EXISTS inventory_collection_transfers (
        source_resource VARCHAR(100) NOT NULL,operation_id VARCHAR(128) NOT NULL,
        request_json LONGTEXT NOT NULL,result_json LONGTEXT NULL,
        PRIMARY KEY(source_resource,operation_id)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]])
end
function C.Allowed(p,row)
    local m=type(row.metadata)=='table' and row.metadata or InventoryMetadata.Decode(row.metadata)
    return p.items[row.name]==true and row.instance_mode=='unique' and row.type=='item_item'
        and type(m)=='table' and (not p.marker or type(m[p.marker])=='string' and #m[p.marker]>0)
end
function C.Resolve(tx,p)
    local rows=tx.query([[SELECT inventory_id FROM inventory_character_collections
        WHERE source_resource=? AND collection_key=? AND character_id=? FOR UPDATE]],{p.resource,p.key,p.characterId})
    local id=rows[1] and tonumber(rows[1].inventory_id)
    if id then
        local inv=tx.query([[SELECT id,location,character_id,owner_character_id,is_public,max_slots FROM inventory WHERE id=? FOR UPDATE]],{id})[1]
        if not inv or inv.location~='character_collection' or inv.character_id~=nil or inv.owner_character_id~=nil
            or tonumber(inv.is_public)~=0 then return bad('collection_corrupt','Collection identity changed; no items moved.') end
        if tonumber(inv.max_slots)~=p.maxItems then tx.query('UPDATE inventory SET max_slots=? WHERE id=?',{p.maxItems,id}) end
        return Result.Ok({id=id})
    end
    local created=tx.query([[INSERT INTO inventory
        (uuid,location,name,max_weight,ignore_item_limit,max_slots,is_public)
        VALUES (UUID(),'character_collection',?,0,1,?,0) RETURNING id]],{p.key,p.maxItems})
    id=created[1] and tonumber(created[1].id)
    if not id then return bad() end
    tx.query([[INSERT INTO inventory_character_collections (source_resource,collection_key,character_id,inventory_id)
        VALUES (?,?,?,?)]],{p.resource,p.key,p.characterId,id})
    return Result.Ok({id=id})
end
local function carried(query,p,lock)
    local names={};for name,allowed in pairs(p.items) do if allowed==true then names[#names+1]=name end end;table.sort(names)
    if #names==0 then return {} end
    local marks,params={},{p.characterId}
    for _,name in ipairs(names) do marks[#marks+1]='?';params[#params+1]=name end
    return query([[SELECT ii.id,ii.inventory_id,ii.item_id,ii.slot_index,ii.row_revision,ii.metadata,i.name,i.type,i.instance_mode
        FROM inventory_items ii INNER JOIN inventory inv ON inv.id=ii.inventory_id INNER JOIN items i ON i.id=ii.item_id
        WHERE inv.character_id=? AND i.name IN (]]..table.concat(marks,',')..') ORDER BY ii.id'..(lock and ' FOR UPDATE' or ''),params)
end
function C.Get(request,resource)
    local checked=policy(request,resource);if not checked.ok then return checked end
    local p=checked.value
    local adopt=request.adopt==true
    local existing=DB.query([[SELECT i.id,i.location,i.character_id,i.owner_character_id,i.is_public,i.max_slots
        FROM inventory_character_collections c INNER JOIN inventory i ON i.id=c.inventory_id
        WHERE c.source_resource=? AND c.collection_key=? AND c.character_id=?]],p.resource,p.key,p.characterId)[1]
    if existing then
        if existing.location~='character_collection' or existing.character_id~=nil or existing.owner_character_id~=nil
            or tonumber(existing.is_public)~=0 then return bad('collection_corrupt') end
        local needed=false
        if adopt then for _,row in ipairs(carried(function(sql,params) return DB.query(sql,table.unpack(params)) end,p,false)) do
            if C.Allowed(p,row) then needed=true;break end
        end end
        if not needed and tonumber(existing.max_slots)==p.maxItems then return Result.Ok({id=tonumber(existing.id),maxItems=p.maxItems}) end
    end
    return TransactionAPI.Transaction({resource=resource,reason='character_collection'},function(tx)
        local resolved=C.Resolve(tx,p);if not resolved.ok then return resolved end
        local id=resolved.value.id
        if adopt then
            local rows=carried(tx.query,p,true)
            local occupied=tx.query('SELECT slot_index FROM inventory_items WHERE inventory_id=? ORDER BY id FOR UPDATE',{id})
            local used={};for _,row in ipairs(occupied) do used[tonumber(row.slot_index) or 0]=true end
            local count=#occupied;local nextSlot=0;local moved={}
            for _,row in ipairs(rows) do if C.Allowed(p,row) then
                count=count+1;if count>p.maxItems then return bad('collection_full','Tack collection is full; existing items remain in place.') end
                local allowed,reason=GuardsAPI.CanChangeInstance(tonumber(row.id),{operation='collection_adoption',resource=resource})
                if allowed~=true then return bad('denied',reason) end
                while used[nextSlot] do nextSlot=nextSlot+1 end
                if nextSlot>=p.maxItems then return bad('collection_full','Collection slots are full.') end
                moved[#moved+1]={id=tonumber(row.id),slot=nextSlot}
                -- Deliberately retain equipment: custody changes, ownership does not.
                tx.moved=tx.moved or {};tx.moved[#tx.moved+1]={instanceId=tonumber(row.id),fromInventoryId=tonumber(row.inventory_id),
                    toInventoryId=id,definitionId=tonumber(row.item_id),fromSlot=tonumber(row.slot_index),toSlot=nextSlot,
                    revision=(tonumber(row.row_revision) or 0)+1}
                used[nextSlot]=true
            end end
            -- Bounded batches, one transaction: no per-piece database round trips.
            for first=1,#moved,100 do
                local cases,marks,params={},{},{id}
                local last=math.min(first+99,#moved)
                for n=first,last do cases[#cases+1]='WHEN ? THEN ?';params[#params+1]=moved[n].id;params[#params+1]=moved[n].slot end
                for n=first,last do marks[#marks+1]='?';params[#params+1]=moved[n].id end
                local saved=tx.query('UPDATE inventory_items SET inventory_id=?,slot_index=CASE id '..table.concat(cases,' ')..
                    ' END,row_revision=row_revision+1 WHERE id IN ('..table.concat(marks,',')..')',params)
                if not saved or tonumber(saved.affectedRows or saved.affected_rows)~=last-first+1 then return bad('collection_conflict') end
            end
        end
        return Result.Ok({id=id,maxItems=p.maxItems})
    end)
end
function C.Item(request,resource)
    local checked=policy(request,resource);if not checked.ok then return checked end
    if type(request.instanceId)~='number' or request.instanceId<1 or request.instanceId%1~=0 then return bad('invalid_input') end
    local p=checked.value;local instanceId=request.instanceId
    local rows=DB.query([[SELECT ii.id,ii.inventory_id,ii.metadata,i.name,i.type,i.instance_mode
        FROM inventory_character_collections c INNER JOIN inventory inv ON inv.id=c.inventory_id
            AND inv.location='character_collection' AND inv.character_id IS NULL AND inv.owner_character_id IS NULL AND inv.is_public=0
        INNER JOIN inventory_items ii ON ii.inventory_id=c.inventory_id
        INNER JOIN items i ON i.id=ii.item_id WHERE c.source_resource=? AND c.collection_key=? AND c.character_id=? AND ii.id=?]],
        p.resource,p.key,p.characterId,instanceId)
    if not rows[1] or not C.Allowed(p,rows[1]) then return bad('not_found','Collection item is not owned.') end
    local item=InstancesAPI.GetInstance(instanceId)
    if not item.ok or item.value.inventoryId~=tonumber(rows[1].inventory_id) then return bad('not_found') end
    return item
end
function C.Batch(request,resource)
    local checked=policy(request,resource);if not checked.ok then return checked end
    local p=checked.value
    local row=DB.query([[SELECT inventory_id FROM inventory_character_collections
        WHERE source_resource=? AND collection_key=? AND character_id=?]],p.resource,p.key,p.characterId)[1]
    if not row then return bad('not_found') end
    return EquipmentAPI.SetCollectionEquipmentBatch(p.characterId,request.changes,tonumber(row.inventory_id),p)
end

-- Durable exact-instance surrender. A committed receipt is historical even after
-- deletion; replay never removes another item. Expected equipment is scoped to
-- these exact instances, so a newly fitted/moved piece cannot be sold by stale UI.
function C.Retire(request,resource)
    local checked=policy(request,resource);if not checked.ok then return checked end
    local p=checked.value
    if type(request.operationId)~='string' or #request.operationId>128 or not request.operationId:match('^[%w._:%-]+$')
        or type(request.items)~='table' or #request.items<1 or #request.items>16 or type(request.equipment)~='table' then return bad('invalid_input') end
    local items,ids,slots={},{},{}
    for _,item in ipairs(request.items) do
        if type(item)~='table' or type(item.instanceId)~='number' or item.instanceId<1 or item.instanceId%1~=0
            or ids[item.instanceId] or type(item.revision)~='number' or item.revision<0 or item.revision%1~=0 then return bad('invalid_input') end
        ids[item.instanceId]=true;items[#items+1]={instanceId=item.instanceId,revision=item.revision}
    end
    table.sort(items,function(a,b) return a.instanceId<b.instanceId end)
    for slot,id in pairs(request.equipment) do
        if type(slot)~='string' or #slot<1 or #slot>50 or id~=0 and not ids[id] then return bad('invalid_input') end
        slots[#slots+1]={slot=slot,id=id}
    end
    table.sort(slots,function(a,b) return a.slot<b.slot end)
    if #slots>32 then return bad('invalid_input') end
    local parts={p.characterId,p.key}
    for _,item in ipairs(items) do parts[#parts+1]=('i:%d:%d'):format(item.instanceId,item.revision) end
    for _,slot in ipairs(slots) do parts[#parts+1]='s:'..#slot.slot..':'..slot.slot..':'..slot.id end
    local fingerprint=table.concat(parts,'|');local operationId=request.operationId
    return TransactionAPI.Transaction({resource=resource,reason='collection_retirement',correlationId=operationId},function(tx)
        tx.query([[INSERT IGNORE INTO inventory_collection_retirements(source_resource,operation_id,request_json)
            VALUES(?,?,?)]],{resource,operationId,fingerprint})
        local receipt=tx.query([[SELECT request_json,result_json FROM inventory_collection_retirements
            WHERE source_resource=? AND operation_id=? FOR UPDATE]],{resource,operationId})[1]
        if not receipt or receipt.request_json~=fingerprint then return bad('idempotency_conflict') end
        if receipt.result_json then
            local ok,value=pcall(json.decode,receipt.result_json)
            if not ok or type(value)~='table' or value.retired~=true or value.operationId~=operationId
                or value.characterId~=p.characterId then return bad('collection_corrupt') end
            value.replayed=true;return Result.Ok(value)
        end
        local resolved=C.Resolve(tx,p);if not resolved.ok then return resolved end
        local inventoryId=resolved.value.id
        local locked={}
        for _,item in ipairs(items) do
            local read=tx:GetItemForUpdate(item.instanceId)
            if not read.ok or read.value.inventoryId~=inventoryId or read.value.revision~=item.revision then return bad('collection_conflict') end
            local i=read.value
            if not C.Allowed(p,{name=i.definition.name,type=i.definition.type,instance_mode=i.definition.instanceMode,metadata=i.metadata}) then return bad('collection_conflict') end
            locked[#locked+1]=i
        end
        local marks,params={},{p.characterId}
        for _,item in ipairs(items) do marks[#marks+1]='?';params[#params+1]=item.instanceId end
        local slotMarks,expected={},{}
        local positive=0
        for _,slot in ipairs(slots) do
            slotMarks[#slotMarks+1]='?';params[#params+1]=slot.slot;expected[slot.slot]=slot.id
            if slot.id>0 then positive=positive+1 end
        end
        local sql='SELECT slot,inventory_items_id FROM character_equipment WHERE character_id=? AND (inventory_items_id IN ('..table.concat(marks,',')..')'
        if #slotMarks>0 then sql=sql..' OR slot IN ('..table.concat(slotMarks,',')..')' end
        local equipment=tx.query(sql..') ORDER BY slot FOR UPDATE',params)
        if #equipment~=positive then return bad('collection_conflict') end
        for _,row in ipairs(equipment) do
            if expected[row.slot]~=tonumber(row.inventory_items_id) then return bad('collection_conflict') end
        end
        local deleteParams={p.characterId};for _,item in ipairs(items) do deleteParams[#deleteParams+1]=item.instanceId end
        for _,item in ipairs(items) do
            local allowed,reason=GuardsAPI.CanChangeInstance(item.instanceId,{operation='equipment_write',resource=resource})
            if allowed~=true then return bad('denied',reason) end
        end
        tx.query('DELETE FROM character_equipment WHERE character_id=? AND inventory_items_id IN ('..table.concat(marks,',')..')',deleteParams)
        for _,item in ipairs(locked) do
            local removed=tx:RemoveInstances(inventoryId,item.definition.id,{item.id})
            if not removed.ok then return removed end
        end
        local value={operationId=operationId,characterId=p.characterId,retired=true,count=#items,replayed=false}
        local saved=tx.query('UPDATE inventory_collection_retirements SET result_json=? WHERE source_resource=? AND operation_id=?',
            {json.encode(value),resource,operationId})
        if not saved or tonumber(saved.affectedRows or saved.affected_rows)~=1 then return bad() end
        return Result.Ok(value)
    end)
end

-- Atomic custody handover: preserve IDs, metadata and assembly assignments.
function C.Transfer(request,resource)
    local checked=policy(request,resource);if not checked.ok then return checked end
    local p=checked.value
    local target=policy({characterId=request.recipientCharacterId,collectionKey=request.collectionKey},resource)
    if not target.ok then return target end
    local recipient=target.value
    if recipient.characterId==p.characterId then return bad('invalid_input') end
    if type(request.operationId)~='string' or #request.operationId>128 or not request.operationId:match('^[%w._:%-]+$')
        or type(request.items)~='table' or #request.items<1 or #request.items>16 or type(request.equipment)~='table' then return bad('invalid_input') end
    local items,ids,slots={},{},{}
    for _,item in ipairs(request.items) do
        if type(item)~='table' or type(item.instanceId)~='number' or item.instanceId<1 or item.instanceId%1~=0
            or ids[item.instanceId] or type(item.revision)~='number' or item.revision<0 or item.revision%1~=0 then return bad('invalid_input') end
        ids[item.instanceId]=true;items[#items+1]={instanceId=item.instanceId,revision=item.revision}
    end
    table.sort(items,function(a,b) return a.instanceId<b.instanceId end)
    for slot,id in pairs(request.equipment) do
        if type(slot)~='string' or #slot<1 or #slot>50 or id~=0 and not ids[id] then return bad('invalid_input') end
        slots[#slots+1]={slot=slot,id=id}
    end
    table.sort(slots,function(a,b) return a.slot<b.slot end)
    if #slots>32 then return bad('invalid_input') end
    local parts={p.characterId,recipient.characterId,p.key}
    for _,item in ipairs(items) do parts[#parts+1]=('i:%d:%d'):format(item.instanceId,item.revision) end
    for _,slot in ipairs(slots) do parts[#parts+1]='s:'..#slot.slot..':'..slot.slot..':'..slot.id end
    local fingerprint=table.concat(parts,'|');local operationId=request.operationId
    return TransactionAPI.Transaction({resource=resource,reason='collection_transfer',correlationId=operationId},function(tx)
        tx.query([[INSERT IGNORE INTO inventory_collection_transfers(source_resource,operation_id,request_json)
            VALUES(?,?,?)]],{resource,operationId,fingerprint})
        local receipt=tx.query([[SELECT request_json,result_json FROM inventory_collection_transfers
            WHERE source_resource=? AND operation_id=? FOR UPDATE]],{resource,operationId})[1]
        if not receipt or receipt.request_json~=fingerprint then return bad('idempotency_conflict') end
        if receipt.result_json then
            local ok,value=pcall(json.decode,receipt.result_json)
            if not ok or type(value)~='table' or value.transferred~=true or value.operationId~=operationId
                or value.characterId~=p.characterId or value.recipientCharacterId~=recipient.characterId then return bad('collection_corrupt') end
            value.replayed=true;return Result.Ok(value)
        end
        -- Lock the two collection containers in character order for opposite offers.
        local scopes={p,recipient};table.sort(scopes,function(a,b) return a.characterId<b.characterId end)
        local containers={}
        for _,scope in ipairs(scopes) do
            local resolved=C.Resolve(tx,scope);if not resolved.ok then return resolved end
            containers[scope.characterId]=resolved.value.id
        end
        local inventoryId,targetId=containers[p.characterId],containers[recipient.characterId]
        local occupied=tx.query('SELECT slot_index FROM inventory_items WHERE inventory_id=? ORDER BY id FOR UPDATE',{targetId})
        if #occupied+#items>recipient.maxItems then return bad('collection_full') end
        local used={};for _,row in ipairs(occupied) do used[tonumber(row.slot_index) or 0]=true end
        local locked={}
        for _,item in ipairs(items) do
            local read=tx:GetItemForUpdate(item.instanceId)
            if not read.ok or read.value.inventoryId~=inventoryId or read.value.revision~=item.revision then return bad('collection_conflict') end
            local i=read.value
            if not C.Allowed(p,{name=i.definition.name,type=i.definition.type,instance_mode=i.definition.instanceMode,metadata=i.metadata}) then return bad('collection_conflict') end
            locked[#locked+1]=i
        end
        local marks={}
        for _,item in ipairs(items) do marks[#marks+1]='?' end
        local slotMarks,expected={},{}
        local positive=0
        for _,slot in ipairs(slots) do
            slotMarks[#slotMarks+1]='?';expected[slot.slot]=slot.id
            if slot.id>0 then positive=positive+1 end
        end
        -- Selected IDs must not be assigned to any other character either.
        local params2={};for _,item in ipairs(items) do params2[#params2+1]=item.instanceId end
        local sql='SELECT character_id,slot,inventory_items_id FROM character_equipment WHERE (inventory_items_id IN ('..table.concat(marks,',')..')'
        if #slotMarks>0 then
            sql=sql..' OR (character_id=? AND slot IN ('..table.concat(slotMarks,',')..'))'
            params2[#params2+1]=p.characterId;for _,slot in ipairs(slots) do params2[#params2+1]=slot.slot end
        end
        local equipment=tx.query(sql..') ORDER BY character_id,slot FOR UPDATE',params2)
        if #equipment~=positive then return bad('collection_conflict') end
        for _,row in ipairs(equipment) do
            if row.character_id~=p.characterId or expected[row.slot]~=tonumber(row.inventory_items_id) then return bad('collection_conflict') end
        end
        -- The owning resource attests transferable assembly anchors. Every selected
        -- assignment is compared above; recipient slots must still be empty.
        if #slots>0 then
            local destination={recipient.characterId}
            for _,slot in ipairs(slots) do destination[#destination+1]=slot.slot end
            if #tx.query('SELECT inventory_items_id FROM character_equipment WHERE character_id=? AND slot IN ('..
                table.concat(slotMarks,',')..') ORDER BY slot FOR UPDATE',destination)>0 then return bad('collection_conflict') end
        end
        local nextSlot=0
        for _,item in ipairs(locked) do
            local allowed,reason=GuardsAPI.CanChangeInstance(item.id,{operation='equipment_write',resource=resource})
            if allowed~=true then return bad('denied',reason) end
            item.equipmentSnapshot={equipped=false}
            for _,slot in ipairs(slots) do if slot.id==item.id then item.equipmentSnapshot.equipped=true end end
            allowed,reason=GuardsAPI.CanMoveInstanceSnapshot(item,{reason='collection_transfer',resource=resource,correlationId=operationId})
            if allowed~=true then return bad('denied',reason) end
            while used[nextSlot] do nextSlot=nextSlot+1 end
            if nextSlot>=recipient.maxItems then return bad('collection_full') end
            local moved=tx.query('UPDATE inventory_items SET inventory_id=?,slot_index=?,row_revision=row_revision+1 WHERE id=? AND inventory_id=? AND row_revision=?',
                {targetId,nextSlot,item.id,inventoryId,item.revision})
            if not moved or tonumber(moved.affectedRows or moved.affected_rows)~=1 then return bad('collection_conflict') end
            tx.moved=tx.moved or {};tx.moved[#tx.moved+1]={instanceId=item.id,fromInventoryId=inventoryId,toInventoryId=targetId,
                definitionId=item.definition.id,fromSlot=item.slot,toSlot=nextSlot,revision=item.revision+1}
            used[nextSlot]=true
        end
        for _,slot in ipairs(slots) do if slot.id>0 then
            local moved=tx.query('UPDATE character_equipment SET character_id=? WHERE character_id=? AND slot=? AND inventory_items_id=?',
                {recipient.characterId,p.characterId,slot.slot,slot.id})
            if not moved or tonumber(moved.affectedRows or moved.affected_rows)~=1 then return bad('collection_conflict') end
        end end
        local value={operationId=operationId,characterId=p.characterId,recipientCharacterId=recipient.characterId,
            transferred=true,count=#items,replayed=false}
        local saved=tx.query('UPDATE inventory_collection_transfers SET result_json=? WHERE source_resource=? AND operation_id=?',
            {json.encode(value),resource,operationId})
        if not saved or tonumber(saved.affectedRows or saved.affected_rows)~=1 then return bad() end
        return Result.Ok(value)
    end)
end
