-- Item-attached storage reuses ordinary Inventory containers, UI and mutations.
-- Custody follows the unique collection item; no character ownership is copied.
CollectionStorageAPI={}
local S=CollectionStorageAPI
local policies,managed={},{}
local function bad(code) return Result.Err(code or 'storage_unavailable','Item storage is unavailable.') end
local function callable(v) return type(v)=='function' or type(v)=='table' and type(rawget(v,'__cfx_functionReference'))=='string' end
local function key(resource,collection) return resource..':'..collection end
local function query(sql,params) return DB.query(sql,table.unpack(params or {})) end
function S.Start()
    DB.exec([[CREATE TABLE IF NOT EXISTS inventory_collection_storage (
        instance_id BIGINT UNSIGNED NOT NULL PRIMARY KEY,
        source_resource VARCHAR(100) NOT NULL,collection_key VARCHAR(100) NOT NULL,
        inventory_id BIGINT UNSIGNED NOT NULL,UNIQUE KEY storage_inventory(inventory_id)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]])
    for _,row in ipairs(DB.query('SELECT inventory_id FROM inventory_collection_storage')) do managed[tonumber(row.inventory_id)]=true end
end
function S.Register(p,resource)
    local scope=type(p)=='table' and Config.TrustedCharacterCollections and Config.TrustedCharacterCollections[resource or '']
    scope=scope and scope[p.collectionKey]
    if not scope or not scope.storageItems or scope.storageItems[p.itemName]~=true or not callable(p.validate)
        or type(p.slots)~='number' or p.slots%1~=0 or p.slots<1 or p.slots>500
        or type(p.maxWeight)~='number' or p.maxWeight~=p.maxWeight or p.maxWeight<=0 or p.maxWeight>100000 then return bad('invalid_input') end
    policies[key(resource,p.collectionKey)]={resource=resource,collectionKey=p.collectionKey,itemName=p.itemName,
        slots=p.slots,maxWeight=p.maxWeight,validate=p.validate}
    return Result.Ok(true)
end
function S.IsManaged(id) return managed[tonumber(id)]==true end
function S.Access(src,id,mode,boundQuery)
    local run=boundQuery or query
    local identity=InventoryIdentity.GetSession(src)
    if not identity.ok or mode=='manage' then return false end
    -- Lock custody before checking the live consumer predicate. Transfers and
    -- retirement lock the same unique item; mutations cannot outlive its owner.
    local rows=run([[SELECT s.instance_id,s.source_resource,s.collection_key,i.name
        FROM inventory_collection_storage s
        INNER JOIN inventory storage ON storage.id=s.inventory_id AND storage.location='collection_storage'
        INNER JOIN inventory_items ii ON ii.id=s.instance_id
        INNER JOIN items i ON i.id=ii.item_id
        INNER JOIN inventory_character_collections c ON c.inventory_id=ii.inventory_id
            AND c.source_resource=s.source_resource AND c.collection_key=s.collection_key
        WHERE s.inventory_id=? AND c.character_id=?]]..(boundQuery and ' FOR UPDATE' or ''),{id,identity.value.characterId})
    local row=rows[1];local p=row and policies[key(row.source_resource,row.collection_key)]
    if not p or row.name~=p.itemName or GetResourceState(p.resource)~='started' then return false end
    local ok,allowed=pcall(p.validate,src,tonumber(row.instance_id),mode)
    if not ok or allowed~=true then return false end
    return true
end
function S.Get(request,resource)
    local scope=CharacterCollectionAPI.Validate(request,resource);if not scope.ok then return scope end
    local item=CharacterCollectionAPI.Item(request,resource);if not item.ok then return item end
    local p=policies[key(resource,request.collectionKey)]
    if not p or item.value.definition.name~=p.itemName then return bad('storage_not_supported') end
    local result=TransactionAPI.Transaction({resource=resource,reason='collection_storage'},function(tx)
        local custody=CharacterCollectionAPI.Resolve(tx,scope.value);if not custody.ok then return custody end
        local held=tx:GetItemForUpdate(request.instanceId)
        if not held.ok or held.value.inventoryId~=custody.value.id then return bad('collection_conflict') end
        local row=tx.query('SELECT inventory_id FROM inventory_collection_storage WHERE instance_id=? FOR UPDATE',{request.instanceId})[1]
        if not row and request.create~=true then return Result.Ok({itemCount=0,contents={},contentsRevision='empty',contentsVersion=1}) end
        local id=row and tonumber(row.inventory_id)
        if not id then
            local created=tx.query([[INSERT INTO inventory(uuid,location,name,max_weight,ignore_item_limit,max_slots,is_public)
                VALUES(UUID(),'collection_storage',?, ?,0,?,0) RETURNING id]],{request.name or 'Saddlebags',p.maxWeight,p.slots})[1]
            if not created then return bad() end;id=tonumber(created.id)
            tx.query('INSERT INTO inventory_collection_storage(instance_id,source_resource,collection_key,inventory_id) VALUES(?,?,?,?)',
                {request.instanceId,resource,request.collectionKey,id})
        end
        local inv=tx.query('SELECT uuid,location FROM inventory WHERE id=? FOR UPDATE',{id})[1]
        if not inv or inv.location~='collection_storage' then return bad('collection_corrupt') end
        tx.query('UPDATE inventory SET max_slots=?,max_weight=? WHERE id=?',{p.slots,p.maxWeight,id})
        local contents=tx.query('SELECT DISTINCT slot_index FROM inventory_items WHERE inventory_id=? ORDER BY slot_index',{id})
        local value={id=id,uuid=inv.uuid,itemCount=#contents,instanceId=request.instanceId}
        if request.snapshot==true then
            local rows=tx.query([[SELECT ii.id,ii.item_id,ii.slot_index,ii.row_revision,ii.metadata,i.name,i.display_name
                FROM inventory_items ii INNER JOIN items i ON i.id=ii.item_id
                WHERE ii.inventory_id=? ORDER BY ii.id]],{id})
            local hash=-3750763034362895579;local grouped={}
            local function feed(text)
                text=tostring(text);text=#text..':'..text
                for n=1,#text do hash=(hash ~ text:byte(n))*1099511628211 end
            end
            for _,item in ipairs(rows) do
                for _,field in ipairs({'id','item_id','slot_index','row_revision','metadata'}) do feed(item[field]) end
                local group=grouped[item.name] or {itemName=item.name,itemLabel=item.display_name or item.name,quantity=0}
                group.quantity=group.quantity+1;grouped[item.name]=group
            end
            value.contents={}
            for _,entry in pairs(grouped) do value.contents[#value.contents+1]=entry end
            table.sort(value.contents,function(a,b) return a.itemName<b.itemName end)
            value.contentsRevision=string.format('%016x',hash);value.contentsVersion=1
        end
        return Result.Ok(value)
    end)
    if result.ok and result.value.id then managed[result.value.id]=true end
    return result
end
function S.Open(request,resource)
    local identity=type(request)=='table' and InventoryIdentity.GetSession(request.source)
    if not identity or not identity.ok or identity.value.characterId~=request.characterId then return bad('denied') end
    local p=policies[key(resource,request.collectionKey)]
    if not p then return bad('storage_not_supported') end
    local ok,allowed=pcall(p.validate,request.source,request.instanceId,'read')
    if not ok or allowed~=true then return bad('denied') end
    request.create=true
    local found=S.Get(request,resource);if not found.ok then return found end
    if not S.Access(request.source,found.value.id,'read') then return bad('denied') end
    return InventoryAPI.OpenInventory(request.source,found.value.uuid)
end
function S.RequireEmpty(tx,instanceId)
    local row=tx.query('SELECT inventory_id FROM inventory_collection_storage WHERE instance_id=? FOR UPDATE',{instanceId})[1]
    if not row then return nil end
    local id=tonumber(row.inventory_id)
    tx.query('SELECT id FROM inventory WHERE id=? FOR UPDATE',{id})
    if #tx.query('SELECT id FROM inventory_items WHERE inventory_id=? LIMIT 1 FOR UPDATE',{id})>0 then return bad('storage_not_empty') end
end
AddEventHandler('onResourceStop',function(resource)
    for k,p in pairs(policies) do if p.resource==resource then policies[k]=nil end end
end)
