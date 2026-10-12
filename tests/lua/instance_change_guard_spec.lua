local root=arg and arg[1] or '.'
warn=function() end; CreateThread=function() end; TriggerEvent=function() end
Result={Codes={DENIED='denied',INVALID_INPUT='input',INTERNAL='internal',CONFLICT='conflict'},
    Ok=function(value) return {ok=true,value=value} end,
    Err=function(code,message) return {ok=false,error={code=code,message=message}} end}
InventoryIdentity={NormalizeCharacterId=function(id) return id end}
InventoryMutationMetrics={New=function() return {} end,Elapsed=function() return 0 end,
    Measure=function(_,_,fn,...) return fn(...) end}
GetGameTimer=function() return 1 end
json={encode=function() return '{}' end}
local writes,held,rows=0,true,{{slot='primary',inventory_items_id=1},{slot='offhand',inventory_items_id=2}}
local function query(sql)
    if sql:find('INNER JOIN `inventory`',1,true) then return {{id=3}} end
    if sql:match('^%s*SELECT') and sql:find('FROM `character_equipment`',1,true) then return rows end
    if sql:find('SELECT `inventory_id`, `slot_index`',1,true) then return {{inventory_id=4}} end
    if sql:find('FROM `inventory_items`',1,true) then return {{id=1,inventory_id=4,row_revision=2,metadata='{}'}} end
    if sql:find('SELECT `row_revision`',1,true) then return {{row_revision=3}} end
    writes=writes+1; return {affectedRows=1}
end
DB={transaction=function(body) return body({raw=query}) end}
dofile(root..'/server/services/guards.lua')
dofile(root..'/server/services/transactions.lua')
dofile(root..'/server/services/equipment.lua')
local callback=setmetatable({__cfx_functionReference='test'},{__call=function(_,item,context)
    assert(context.operation)
    return not (held and item.id==1),'held'
end})
assert(GuardsAPI.RegisterInstanceChangeGuard('native',callback).ok)
assert(GuardsAPI.HasRegisteredGuard('native'))
assert(not EquipmentAPI.SetEquippedForCharacter('c','primary',nil).ok)
assert(not EquipmentAPI.SetEquippedForCharacter('c','primary',3).ok,'replacement checks displaced copy')
assert(not EquipmentAPI.PromoteEquippedSlot('c','offhand','primary').ok,'promotion checks displaced copy')
assert(not EquipmentAPI.ClearEquippedInstance(1).ok)
local result=TransactionAPI.Transaction({},function(tx) return tx:SetMetadata(1,{},2) end)
assert(not result.ok and result.error.code=='denied' and writes==0,'held metadata cannot write')
held=false
assert(EquipmentAPI.SetEquippedForCharacter('c','primary',nil).ok and writes==1)
GuardsAPI.RegisterInstanceChangeGuard('native',function() error('stopped reference') end)
assert(not EquipmentAPI.ClearEquippedInstance(1).ok and writes==1,'errored reference fails closed')
GuardsAPI.UnregisterInstanceChangeGuard('native')
assert(not GuardsAPI.HasRegisteredGuard('native'))
local command,output
Config={DevMode=true}
GetResourceState=function() return 'stopped' end
InventoryIdentity.GetSession=function() return {ok=true,value={characterId='c',sessionId='s'}} end
local smokeExport
exports=setmetatable({['feather-core']={IsSessionCurrent=function() return true end}},
    {__call=function(_,_,fn) smokeExport=fn end})
InventoryMetadata={Decode=function() return {} end,DocumentsEqual=function() return true end}
RegisterCommand=function(_,fn) command=fn end
local persistedRevision=2
TransactionAPI.Transaction=function(_,body)
    local tx={query=function(sql)
        if sql:find('SELECT id FROM inventory',1,true) then return {{id=4}} end
        return {{id=1,row_revision=2,metadata='{}'}}
    end,GetItemForUpdate=function() return Result.Ok({id=1,revision=2,metadata={}}) end}
    function tx:SetMetadata(id,doc,revision)
        local allowed,reason=GuardsAPI.CanChangeInstance(id,{operation='metadata_write'})
        if not allowed then return Result.Err('denied',reason) end
        persistedRevision=revision+1; return Result.Ok({revision=persistedRevision})
    end
    local result=body(tx); persistedRevision=2; return result
end
DB.query=function() return {{id=1,row_revision=persistedRevision,metadata='{}'}} end
local originalPrint=print; output={}; print=function(value) output[#output+1]=value end
dofile(root..'/server/services/instance_change_guard_test.lua')
command(0,{'1'})
print=originalPrint
assert(output[#output]:find('done 8/8',1,true),'rollback command reports all eight gates')
assert(not GuardsAPI.HasRegisteredGuard('feather-inventory:instance-change-smoke'),'smoke guard must not leak')
local caller='foreign'
GetInvokingResource=function() return caller end
local function cfx(fn)
    return setmetatable({__cfx_functionReference='mock'},{__call=function(_,...) return fn(...) end})
end
local provider={Bind=cfx(function(id)
    local active=true
    return {guard=cfx(function(item) return not (active and item.id==id),'held' end),
        release=cfx(function() active=false; return true end)}
end)}
assert(not smokeExport(1,provider).ok,'foreign smoke caller rejected')
caller='feather-weapons-native-proof'
assert(smokeExport(1,provider).ok,'CFX-shaped Bind/guard/release callback tables accepted')
assert(not GuardsAPI.HasRegisteredGuard('feather-inventory:instance-change-smoke'))
print('PASS item-lifetime holds: callable references, metadata, clear, replacement, promotion, release, failure closed')
