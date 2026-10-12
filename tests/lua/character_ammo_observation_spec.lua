local function copy(v)
    if type(v)~='table' then return v end
    local r={}; for k,x in pairs(v) do r[k]=copy(x) end; return r
end
local docs,n={},0
json={encode=function(v) n=n+1; docs[tostring(n)]=copy(v); return tostring(n) end,
    decode=function(v) assert(docs[v]); return copy(docs[v]) end}
Result={Codes={INVALID_INPUT='invalid',DENIED='denied',NOT_FOUND='missing',CONFLICT='conflict',LIMIT_EXCEEDED='limit'},
    Ok=function(v) return {ok=true,value=v} end,Err=function(c,m) return {ok=false,error={code=c,message=m}} end,
    IsOk=function(v) return v and v.ok end}
local char,sessionCurrent='char',true
Config={CharacterAmmunitionEnabled=false,DevMode=true}
InventoryIdentity={NormalizeCharacterId=function(id) return id==char and id end,
    GetSession=function() return {ok=true,value={characterId=char,sessionId='session'}} end}
exports={['feather-core']={IsSessionCurrent=function() return sessionCurrent end},
    ['feather-weapons']={ValidateCharacterAmmoRuntimeOperation=function() return true end}}
local commands={}; RegisterCommand=function(name,fn) commands[name]=fn end
GetResourceState=function() return 'stopped' end
GuardsAPI={HasRegisteredGuard=function() return false end}
dofile('server/helpers/metadata_compatibility.lua')
dofile('server/services/character_ammunition.lua')
local database,writes,casFail,expireOnWrite
local limits={ammo_repeater_regular=200,ammo_repeater_express=200}
local baseline={ammo_repeater_regular=8,ammo_repeater_express=4}
local original={weaponDefinitionId='gun',serial='KEEP',ammo={type='ammo_repeater_regular',loaded=7,reserve=1,pools=copy(baseline)}}
local function reset()
    database={ledger={revision=4,pools=json.encode(baseline)},receipt=nil,
        rows={{id=52,row_revision=1,name='weapon_gun',type='item_weapon',metadata=json.encode(original)}}}
    writes,casFail,expireOnWrite,sessionCurrent=0,false,false,true
end
local tx={}
function tx.query(sql,p)
    if sql:find('SELECT id FROM inventory',1,true) then return {{id=1}} end
    if sql:find('SELECT revision, pools',1,true) then return database.ledger and {copy(database.ledger)} or {} end
    if sql:find('FROM inventory_items',1,true) then return copy(database.rows) end
    if sql:find('SELECT result FROM',1,true) then return database.receipt and {{result=database.receipt}} or {} end
    if sql:find('INSERT INTO feather_character',1,true) then database.ledger={revision=0,pools=p[2]}; return {affectedRows=1} end
    if sql:find('INSERT INTO feather_ammunition',1,true) then database.receipt=p[3]; return {affectedRows=1} end
    if sql:find('UPDATE feather_character',1,true) then
        if casFail or p[4]~=database.ledger.revision then return {affectedRows=0} end
        writes=writes+1; database.ledger={revision=p[2],pools=p[1]}
        if expireOnWrite then sessionCurrent=false end
        return {affectedRows=1}
    end
    error(sql)
end
function tx:SetMetadata(id,document,revision)
    assert(id==52 and revision==1)
    database.rows[1].metadata=json.encode(document); database.rows[1].row_revision=2
    return Result.Ok({revision=2})
end
TransactionAPI={Transaction=function(_,body)
    local before=copy(database)
    local ok,result=pcall(body,tx)
    if not ok or not result.ok then database=before end
    return ok and result or Result.Err('exception',tostring(result))
end}
local context={characterId=char,actorSource=1,sessionId='session',runtimeEpoch='epoch',runtimeTicket='ticket'}
local function request(regular,express,revision)
    return {pools={ammo_repeater_regular=regular,ammo_repeater_express=express},expectedRevision=revision,limits=limits}
end
local function observe(spec,caller) return CharacterAmmunitionAPI.Observe(context,spec,caller or 'feather-weapons') end
reset(); assert(not observe(request(7,4,4)).ok,'gate disabled')
Config.CharacterAmmunitionEnabled=true
local guardAllowed,guardThrow=true,false
exports['feather-weapons'].ValidateCharacterAmmoRuntimeOperation=function(_,value,operation,spec)
    if guardThrow then error('resource stopped') end
    assert(value.runtimeEpoch=='epoch' and value.runtimeTicket=='ticket' and operation=='observe')
    return guardAllowed
end
context.runtimeTicket=nil; assert(not observe(request(7,4,4)).ok,'missing runtime ticket rejected'); context.runtimeTicket='ticket'
guardAllowed=false; assert(not observe(request(7,4,4)).ok,'revoked epoch rejected'); guardAllowed=true
guardThrow=true; assert(not observe(request(7,4,4)).ok,'unavailable runtime guard fails closed'); guardThrow=false
assert(not observe(request(7,4,4),'foreign').ok,'caller rejected')
sessionCurrent=false; assert(not observe(request(7,4,4)).ok); sessionCurrent=true
local result=observe(request(7,4,4))
assert(result.ok and result.value.revision==5 and result.value.consumed.ammo_repeater_regular==1 and writes==1)
result=observe(request(7,4,5)); assert(result.ok and not result.value.changed and result.value.revision==5 and writes==1,'idle must not write')
assert(not observe(request(7,4,4)).ok,'stale retry cannot advance')
assert(not observe(request(8,4,5)).ok,'growth refused')
assert(not observe(request(7,nil,5)).ok,'missing pool refused')
local foreign=request(7,4,5); foreign.pools.foreign=0; assert(not observe(foreign).ok)
for _,bad in ipairs({-1,1.5,math.huge,0/0,'3'}) do assert(not observe(request(7,bad,5)).ok) end
assert(not observe(nil).ok)
assert(not observe({pools={},limits={},expectedRevision=5}).ok)
local before=copy(database)
casFail=true; assert(not observe(request(6,4,5)).ok); assert(InventoryMetadata.DocumentsEqual(before,database)); casFail=false
expireOnWrite=true; assert(not observe(request(6,4,5)).ok); assert(InventoryMetadata.DocumentsEqual(before,database),'session revoked before commit must rollback')
reset(); database.ledger.pools='corrupt'; assert(not observe(request(7,4,4)).ok)
reset(); database.ledger=nil; assert(not observe(request(7,4,4)).ok)
reset()
local snapshot=CharacterAmmunitionAPI.Snapshot(context,limits,'feather-weapons')
assert(snapshot.ok and snapshot.value.revision==4 and writes==0)
assert(InventoryMetadata.DocumentsEqual(snapshot.value.pools,baseline),'snapshot preserves totals without credit')
assert(not CharacterAmmunitionAPI.Snapshot(context,limits,'foreign').ok)
database.ledger=nil; assert(not CharacterAmmunitionAPI.Snapshot(context,limits,'feather-weapons').ok,'snapshot never enrolls')
reset()
local originalQuery=tx.query
tx.query=function(sql,p)
    local value=originalQuery(sql,p)
    if sql:find('UPDATE feather_character',1,true) then guardAllowed=false end
    return value
end
before=copy(database)
assert(not observe(request(7,4,4)).ok)
assert(InventoryMetadata.DocumentsEqual(before,database),'runtime revoked during SQL must rollback')
tx.query=originalQuery; guardAllowed=true
reset(); before=copy(database)
tx.query=function(sql,p)
    local value=originalQuery(sql,p)
    if sql:find('UPDATE feather_character',1,true) then Config.CharacterAmmunitionEnabled=false end
    return value
end
assert(not observe(request(7,4,4)).ok)
assert(InventoryMetadata.DocumentsEqual(before,database),'disabled gate before commit must rollback')
Config.CharacterAmmunitionEnabled=true
tx.query=function(sql,p)
    local value=originalQuery(sql,p)
    if sql:find('SELECT revision, pools',1,true) then Config.CharacterAmmunitionEnabled=false end
    return value
end
assert(not CharacterAmmunitionAPI.Snapshot(context,limits,'feather-weapons').ok,
    'snapshot must not return authority after gate shutdown')
Config.CharacterAmmunitionEnabled=true; tx.query=originalQuery
-- Actual real-row smoke wrapper with deterministic mocked DB rollback.
reset()
local transaction=TransactionAPI.Transaction
TransactionAPI.Transaction=function(ctx,body)
    coroutine.yield()
    return transaction(ctx,body)
end
local pendingSpec=request(7,4,4)
local saved
local worker=coroutine.create(function() saved=observe(pendingSpec) end)
assert(coroutine.resume(worker))
pendingSpec.pools.ammo_repeater_regular=0
pendingSpec.limits.ammo_repeater_regular=0
assert(coroutine.resume(worker) and saved.ok)
assert(saved.value.pools.ammo_repeater_regular==7,'caller mutation cannot replace authorized observation')
limits.ammo_repeater_regular=200
reset()
local snapshotLimits=copy(limits)
worker=coroutine.create(function() saved=CharacterAmmunitionAPI.Snapshot(context,snapshotLimits,'feather-weapons') end)
assert(coroutine.resume(worker))
snapshotLimits.ammo_repeater_regular=0
assert(coroutine.resume(worker) and saved.ok and saved.value.pools.ammo_repeater_regular==8,
    'snapshot policy captured before transaction yield')
TransactionAPI.Transaction=transaction
dofile('../feather-weapons/shared/ammunition_migration_preview.lua')
dofile('server/services/character_ammunition_enrollment.lua')
local catalog={weapons={gun={id='gun',itemName='weapon_gun',family='repeater',capacity=7,
    ammunitionType='ammo_repeater_regular',ammunitionTypes={'ammo_repeater_regular','ammo_repeater_express'}}},
    ammunition={ammo_repeater_regular={nativeAmmoName='AMMO_REPEATER'},ammo_repeater_express={nativeAmmoName='AMMO_REPEATER_EXPRESS'}}}
CharacterAmmoCutoverPreview={Load=function() return catalog,WeaponAmmoMigrationPreview,limits end}
dofile('../feather-weapons/shared/character_ammunition.lua')
dofile('../feather-weapons/shared/character_ammunition_runtime.lua')
CharacterAmmoCutoverPreview.LoadRuntime=function() return WeaponCharacterAmmoRuntime end
DB={raw=function() return copy(database.rows) end,one=function() return nil end}
dofile('server/services/character_ammunition_observation_test.lua')
reset(); database.ledger=nil; before=copy(database)
local originalPrint,output=print,{}
print=function(s) output[#output+1]=s end
commands.InvCharacterAmmoObservationSmokeTest(0,{'1'})
local passed=false; for _,line in ipairs(output) do if line:find('done 6/6; rollback=VERIFIED',1,true) then passed=true end end
assert(passed,table.concat(output,'\n'))
assert(InventoryMetadata.DocumentsEqual(before,database))
reset(); database.ledger=nil; before=copy(database); output={}
commands.InvCharacterAmmoRuntimeSmokeTest(0,{'1'})
passed=false; for _,line in ipairs(output) do if line:find('done 11/11; rollback=VERIFIED',1,true) then passed=true end end
assert(passed,table.concat(output,'\n'))
assert(InventoryMetadata.DocumentsEqual(before,database),'runtime fixture must fully rollback')
local originalState=GetResourceState
GetResourceState=function(name) return name=='feather-weapons-native-proof' and 'started' or originalState(name) end
local cfxCalls=0
exports['feather-weapons-native-proof']={CreateInventoryRuntimeFixture=function(_,validator)
    local remote=WeaponCharacterAmmoRuntime.New(function(...) return validator(...) end)
    local proxy={}
    for name,method in pairs(remote) do
        proxy[name]=setmetatable({__cfx_functionReference='mock:'..name},{__call=function(_,...)
            cfxCalls=cfxCalls+1; return method(...)
        end})
    end
    return proxy
end}
reset(); database.ledger=nil; before=copy(database); output={}
commands.InvCharacterAmmoRuntimeCFXSmokeTest(0,{'1'})
passed=false; for _,line in ipairs(output) do if line:find('done 11/11; rollback=VERIFIED',1,true) then passed=true end end
assert(passed,table.concat(output,'\n'))
assert(cfxCalls>10 and InventoryMetadata.DocumentsEqual(before,database),'CFX callable fixture must rollback')
reset(); database.ledger=nil; before=copy(database); output={}
commands.InvCharacterAmmoRuntimeCFXSmokeTest(0,{'1','death'})
passed=false; for _,line in ipairs(output) do if line:find('done 17/17; rollback=VERIFIED',1,true) then passed=true end end
assert(passed,table.concat(output,'\n'))
assert(InventoryMetadata.DocumentsEqual(before,database),'death final commit/seal fixture must fully rollback')
GetResourceState=originalState
print=originalPrint
print('character ammo observation PASS (reductions, no-op, CAS, session rollback, real smoke wrapper)')
