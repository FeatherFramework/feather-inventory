local function copy(v) if type(v)~='table' then return v end; local r={}; for k,x in pairs(v) do r[k]=copy(x) end; return r end
local docs,n={},0
json={encode=function(v) n=n+1; docs[tostring(n)]=copy(v); return tostring(n) end,decode=function(v) return copy(assert(docs[v])) end}
Result={Codes={DENIED='denied',INVALID_INPUT='invalid',NOT_FOUND='missing',CONFLICT='conflict'},
    IsOk=function(v) return type(v)=='table' and v.ok==true end,
    Ok=function(v) return {ok=true,value=v} end,Err=function(c,m) return {ok=false,error={code=c,message=m}} end}
local fixture='00000000-0000-4000-8000-000000000003'
InventoryIdentity={NormalizeCharacterId=function(v) assert(v==fixture); return v end}
InventoryMetadata={DocumentsEqual=function(a,b)
    for k,v in pairs(a) do if b[k]~=v then return false end end
    for k,v in pairs(b) do if a[k]~=v then return false end end; return true
end}
Config={DevMode=true,CharacterAmmunitionEnabled=false}
local caller,current,resource='feather-weapons-native-proof',true,'stopped'
GetInvokingResource=function() return caller end
GetResourceState=function() return resource end
RegisterCommand=function() end
AddEventHandler=function() end
local registered={}
exports=setmetatable({['feather-core']={IsSessionCurrent=function(_,src,sid,char)
    assert(src==1 and sid=='s' and char=='real'); return current
end}},{__call=function(_,name,fn) registered[name]=fn end})
local caps={ammo_revolver_regular=200,ammo_revolver_express=200}
CharacterAmmoCutoverPreview={Load=function() return {},{},copy(caps) end}
InventoryAPI={AccessModes={REMOVE='remove',INSERT='insert'}}
DB={exec=function(sql) assert(sql:find('fi_ammo_native_',1,true)) end}
dofile('server/services/character_ammunition.lua')
local row,transactions,writes,loseOnWrite=nil,0,0,false
local economy
local tx={query=function(sql,p)
    if sql:find('fi_ammo_native_economy',1,true) then
        if sql:find('SELECT',1,true) then assert(p[1]==fixture); return economy and {copy(economy)} or {} end
        if sql:find('INSERT',1,true) then assert(p[1]==fixture); economy={ammunition_id=p[2],loose=p[3],receipts=p[4]}; return {affectedRows=1} end
        assert(p[3]==fixture); economy.loose=p[1]; economy.receipts=p[2]; return {affectedRows=1}
    end
    assert(sql:find('fi_ammo_native_ledger',1,true),'production SQL must never reach DB')
    if sql:find('SELECT',1,true) then assert(p[1]==fixture); return row and {copy(row)} or {} end
    if sql:find('INSERT',1,true) then assert(p[1]==fixture); row={revision=p[2],pools=p[3]}; return {affectedRows=1} end
    if sql:find('UPDATE',1,true) then
        assert(p[3]==fixture); if p[4]~=row.revision then return {affectedRows=0} end
        row={pools=p[1],revision=p[2]}; writes=writes+1; if loseOnWrite then current=false end
        return {affectedRows=1}
    end
    error(sql)
end}
TransactionAPI={Transaction=function(_,body)
    transactions=transactions+1; local before,oldEconomy=copy(row),copy(economy)
    local ok,result=pcall(body,tx)
    if not ok or not result.ok then row=before; economy=oldEconomy end
    assert(ok,result); return result
end}
dofile('server/services/character_ammunition_native_fixture.lua')
local identity={source=1,characterId='real',sessionId='s',epoch='e'}
local baseline={characterId='real',revision=7,pools={ammo_revolver_regular=3,ammo_revolver_express=4}}
local allowed=true
local validator=setmetatable({__cfx_functionReference='test'},{__call=function(_,context,kind)
    return allowed and kind=='observe' and context.runtimeTicket=='ticket'
end})
caller='untrusted'; assert(not registered.BeginNativeAmmoFixture(identity,baseline,caps,validator).ok and transactions==0)
caller='feather-weapons-native-proof'
assert(registered.BeginNativeAmmoFixture(identity,baseline,caps,validator).ok and transactions==1)
assert(not registered.BeginNativeAmmoFixture(identity,baseline,caps,validator).ok)
local context={actorSource=1,characterId='real',sessionId='s',runtimeEpoch='e',runtimeTicket='ticket'}
local spec={expectedRevision=7,pools={ammo_revolver_regular=2,ammo_revolver_express=4},limits=caps}
allowed=false; assert(not registered.ObserveNativeAmmoFixture(context,spec).ok and transactions==1)
allowed=true
local saved=registered.ObserveNativeAmmoFixture(context,spec)
assert(saved.ok and saved.value.characterId=='real' and saved.value.revision==8 and transactions==2 and writes==1)
assert(not registered.ObserveNativeAmmoFixture(context,spec).ok and row.revision==8)
spec.expectedRevision=8; spec.pools.ammo_revolver_regular=3
assert(not registered.ObserveNativeAmmoFixture(context,spec).ok and row.revision==8)
spec.pools.ammo_revolver_regular=1; loseOnWrite=true
assert(not registered.ObserveNativeAmmoFixture(context,spec).ok and row.revision==8,'world loss must roll back short transaction')
current=true; loseOnWrite=false
assert(registered.ReleaseNativeAmmoFixture().ok and row.revision==8,'release preserves evidence')
assert(not registered.ObserveNativeAmmoFixture(context,spec).ok)
assert(not registered.BeginNativeAmmoFixture(identity,baseline,caps,validator).ok and row.revision==8,'old evidence cannot be overwritten')
print('native SQL fixture PASS (short transactions, CFX ticket, isolated SQL, stale/increase refusal, world-loss rollback, preserved evidence)')
row=nil
assert(registered.BeginNativeAmmoFixture(identity,baseline,caps,function(_,kind) return kind=='transfer' end,
    {ammunitionId='ammo_revolver_regular',loose=1}).ok)
local economic={expectedRevision=7,ammunitionId='ammo_revolver_regular',amount=1,operationId='load',limits=caps}
local grant=registered.TransferNativeAmmoFixture(context,economic)
assert(grant.ok and grant.value.revision==8 and economy.loose==0 and row.revision==8)
local replay=registered.TransferNativeAmmoFixture(context,economic)
assert(replay.ok and replay.value.revision==8 and economy.loose==0 and row.revision==8,'receipt replay spends once')
economic.amount=-1
assert(not registered.TransferNativeAmmoFixture(context,economic).ok and economy.loose==0,'changed receipt input rejected')
economic.operationId='unload'; economic.expectedRevision=8
loseOnWrite=true
assert(not registered.TransferNativeAmmoFixture(context,economic).ok and economy.loose==0 and row.revision==8,'lost Core context rolls back ledger/loose/receipt')
current=true; loseOnWrite=false
assert(registered.TransferNativeAmmoFixture(context,economic).ok and economy.loose==1 and row.revision==9)
local receipts=json.decode(economy.receipts)
assert(receipts.load and receipts.unload)
assert(registered.ReleaseNativeAmmoFixture().ok)
assert(not registered.TransferNativeAmmoFixture(context,economic).ok)
print('native SQL economic fixture PASS (actual Apply, isolated loose/receipts, replay, input reuse, world-loss atomic rollback)')
