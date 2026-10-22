local root = arg and arg[1] or '.'
local function copy(v)
    if type(v) ~= 'table' then return v end
    local out = {}; for k, x in pairs(v) do out[k] = copy(x) end; return out
end
local documents, serial = {}, 0
json = { encode = function(v) serial=serial+1; documents[tostring(serial)]=copy(v); return tostring(serial) end,
    decode = function(v) assert(documents[v], 'bad JSON'); return copy(documents[v]) end }
Result = { Ok=function(v) return {ok=true,value=v} end,
    Err=function(c,m) return {ok=false,error={code=c,message=m}} end }
Config = { TrustedUniqueGrantCallers={['bcc-stables']=true}, TrustedIdempotentGrantCallers={['feather-shops']=true} }
RegisterCommand=function() end
InventoryIdentity = {NormalizeCharacterId=function(v)
    return type(v)=='string' and v:match('^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$') and v:lower() or nil
end}
dofile(root..'/server/services/grants_once.lua')
local state, mode, mismatch, capacity, failSave, beforeCreate, badDefinition, missingInventory
local count=0
local function test(name, fn) fn(); count=count+1; print('PASS unique grant '..name) end
local function reset()
    state={receipts={},items={},created=0}; mode='unique'; mismatch=false; capacity=true
    failSave=false; beforeCreate=nil; badDefinition=false; missingInventory=false
end
local tx={query=function(sql,p)
    local key=tostring(p[1])..'|'..tostring(p[2])
    if sql:find('INSERT IGNORE INTO inventory_unique_grant_receipts',1,true) then
        state.receipts[key]=state.receipts[key] or {request_fingerprint=p[3]}; return {}
    elseif sql:find('SELECT request_fingerprint,result_json',1,true) then return {state.receipts[key]}
    elseif sql:find('UPDATE inventory_unique_grant_receipts',1,true) then
        if failSave then return {affectedRows=0} end
        state.receipts[p[2]..'|'..p[3]].result_json=p[1]; return {affectedRows=1}
    elseif sql:find('FROM items',1,true) then
        return {{id=10,name=mismatch and 'other' or 'test_saddle',type=badDefinition and 'item_weapon' or 'item_standard',instance_mode=mode}}
    elseif sql:find('FROM inventory',1,true) then return missingInventory and {} or {{id=5}}
    end
    error(sql)
end}
function tx:CreateInstance(inv,id,metadata)
    assert(inv==5 and id==10)
    if not capacity then return Result.Err('capacity','full') end
    if beforeCreate then beforeCreate() end
    state.created=state.created+1; state.items[300]={metadata=copy(metadata)}
    return Result.Ok({instanceId=300,revision=0})
end
TransactionAPI={Transaction=function(context,body)
    assert(context.idempotencyKey==nil, 'must bypass process cache')
    local snapshot=copy(state)
    local ok,result=pcall(body,tx)
    if not ok or not result.ok then state=snapshot end
    return ok and result or Result.Err('internal',result)
end}
local function request()
    return {grantId='order-1',characterId='10000000-0000-4000-8000-000000000001',definitionId=10,
        itemName='test_saddle',metadata={version=1,durability=100,appearance={coat='brown',parts={1,2}}}}
end
local function grant(r) return UniqueGrantOnceAPI.Grant(r or request(),'bcc-stables') end
local function cancel(r) return UniqueGrantOnceAPI.Cancel(r or request(),'bcc-stables') end
test('creation and receipt commit together; historical replay never replenishes',function()
    reset(); local a=grant(); assert(a.ok and a.value.instanceId==300 and state.created==1)
    state.items={}; dofile(root..'/server/services/grants_once.lua') -- resource reload; receipts persist
    local b=grant(); assert(b.ok and b.value.replayed and b.value.instanceId==300 and state.created==1 and next(state.items)==nil)
    assert(cancel().error.code=='grant_already_delivered')
end)
test('cancellation fences late delivery and is replayable',function()
    reset(); assert(cancel().ok); assert(cancel().value.replayed)
    assert(grant().error.code=='grant_cancelled' and state.created==0)
end)
test('payload binds character definition name and nested metadata',function()
    for _,field in ipairs({'characterId','definitionId','itemName','metadata'}) do
        reset(); assert(grant().ok); local r=request()
        if field=='characterId' then r[field]='20000000-0000-4000-8000-000000000002'
        elseif field=='definitionId' then r[field]=11 elseif field=='itemName' then r[field]='different'
        else r.metadata.appearance.parts[2]=3 end
        assert(grant(r).error.code=='idempotency_conflict')
        assert(cancel(r).error.code=='idempotency_conflict' and state.created==1)
    end
end)
test('canonical metadata ignores object key order and snapshots caller input',function()
    reset(); local r=request(); local a=UniqueGrantOnceAPI.Validate(r,'bcc-stables')
    local reordered=request()
    reordered.metadata={appearance={parts={1,2},coat='brown'},durability=100,version=1}
    reordered.definitionId=10.0
    local b=UniqueGrantOnceAPI.Validate(reordered,'bcc-stables'); assert(a.value.fingerprint==b.value.fingerprint)
    r.metadata.durability=1; assert(a.value.request.metadata.durability==100)
    reset(); r=request(); beforeCreate=function() r.metadata.durability=0 end
    assert(grant(r).ok and state.items[300].metadata.durability==100)
end)
test('unauthorized malformed and unbounded input is refused before SQL',function()
    reset(); assert(not UniqueGrantOnceAPI.Grant(request(),'feather-shops').ok)
    local cases={}; local r=request(); r.quantity=2; cases[#cases+1]=r
    r=request(); r.metadata.self=r.metadata; cases[#cases+1]=r
    r=request(); r.metadata={value=math.huge}; cases[#cases+1]=r
    r=request(); r.metadata={value=string.rep('a',4097)}; cases[#cases+1]=r
    r=request(); r.metadata={value={[1]='a',[3]='b'}}; cases[#cases+1]=r
    r=request(); r.metadata={}; for i=1,129 do r.metadata['x'..i]=i end; cases[#cases+1]=r
    r=request(); r.characterId='bad'; cases[#cases+1]=r
    for _,bad in ipairs(cases) do assert(not grant(bad).ok) end
    assert(next(state.receipts)==nil and state.created==0)
end)
test('weapon and stack definitions cannot use nonweapon unique issuer',function()
    reset(); mode='stack'; assert(not grant().ok and state.created==0 and next(state.receipts)==nil)
    reset(); badDefinition=true; assert(not grant().ok and state.created==0)
    reset(); mismatch=true; assert(grant().error.code=='item_unavailable')
end)
test('capacity missing inventory and receipt-save failures roll back',function()
    reset(); capacity=false; assert(not grant().ok and state.created==0 and next(state.receipts)==nil)
    reset(); missingInventory=true; assert(not grant().ok and state.created==0)
    reset(); failSave=true; assert(not grant().ok and state.created==0 and next(state.receipts)==nil)
    reset(); failSave=true; assert(not cancel().ok and next(state.receipts)==nil)
end)
test('corrupt stored receipt cannot grant again or authorize cancellation',function()
    reset(); assert(grant().ok)
    state.receipts['bcc-stables|order-1'].result_json=json.encode({delivered=true})
    assert(not grant().ok and not cancel().ok and state.created==1)
end)
test('real transaction accepts CFX callable tables',function()
    local env=setmetatable({},{__index=_G})
    env.Config={}; env.InventoryAPI={}; env.GetGameTimer=function() return 0 end
    env.InventoryDelegation=nil
    env.DB={transaction=function(body) return body({raw=function() return {} end}) end}
    env.warn=function() end; env.Result={Ok=Result.Ok,Err=Result.Err,Codes={INVALID_INPUT='invalid',INTERNAL='internal'}}
    env.GuardsAPI={EmitTransactionCommitted=function() end}
    assert(loadfile(root..'/server/services/transactions.lua','t',env))()
    local callable=setmetatable({__cfx_functionReference='fixture'},{__call=function(_,handle)
        assert(type(handle.query)=='function'); return Result.Ok({called=true}) end})
    assert(env.TransactionAPI.Transaction({},callable).value.called)
    assert(not env.TransactionAPI.Transaction({},{}).ok)
end)
test('public unique exports enforce readiness and derive the caller',function()
    reset()
    local registered,caller={},'untrusted'
    local env=setmetatable({},{__index=_G})
    env.exports=function(name,fn) registered[name]=fn end
    env.GetInvokingResource=function() return caller end
    env.ItemsAPI={RegisterInternalUseGuard=function() error('stop after tested registrations') end}
    assert(loadfile(root..'/server/services/api.lua','t',env))()
    pcall(env.StartAPI)
    assert(registered.GrantCharacterUniqueItemOnce(request()).error.code=='not_ready')
    env.InventoryReadiness.state='ready'
    assert(registered.GrantCharacterUniqueItemOnce(request()).error.code=='authorization_denied')
    caller='bcc-stables'
    assert(registered.GrantCharacterUniqueItemOnce(request()).ok)
    assert(registered.CancelCharacterUniqueItemGrant(request()).error.code=='grant_already_delivered')
end)
print(('%d unique grant scenarios passed (mocked SQL; live concurrency pending)'):format(count))
