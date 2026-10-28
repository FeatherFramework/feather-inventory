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
