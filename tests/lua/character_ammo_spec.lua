local function copy(value)
    if type(value) ~= 'table' then return value end
    local result = {}; for key, item in pairs(value) do result[key] = copy(item) end; return result
end
local documents, sequence = {}, 0
json = { encode = function(value)
    sequence = sequence + 1; local key = 'json-' .. sequence; documents[key] = copy(value); return key
end, decode = function(value) assert(documents[value], 'bad json'); return copy(documents[value]) end }
Result = { Codes = { INVALID_INPUT='invalid', DENIED='denied', NOT_FOUND='missing', CONFLICT='conflict', LIMIT_EXCEEDED='limit' },
    Ok = function(value) return { ok=true, value=value } end,
    Err = function(code, message) return { ok=false, error={code=code, message=message} } end,
    IsOk = function(value) return value and value.ok == true end }
Config = { CharacterAmmunitionEnabled=false, DevMode=false }
local char = 'e5e9955d-c29e-11f1-9ae2-e0d55eaa2deb'
InventoryIdentity = { NormalizeCharacterId=function(id) return id == char and id or nil end }
InventoryAPI = { AccessModes={REMOVE='remove',INSERT='insert'} }
local sessionCurrent, casFail, receiptFail, noAccess = true, false, false, false
exports = { ['feather-core']={ IsSessionCurrent=function() return sessionCurrent end },
    ['feather-weapons']={ValidateCharacterAmmoRuntimeOperation=function() return true end} }
function RegisterCommand() end
local database = { quantity=10, revision=0, pools=json.encode({ammo_repeater_regular=2}), receipts={} }
local function query(sql, params)
    if sql:find('SELECT id FROM inventory',1,true) then return {{id=1}} end
    if sql:find('SELECT revision, pools',1,true) then return {{revision=database.revision,pools=database.pools}} end
    if sql:find('SELECT result FROM',1,true) then
        local value=database.receipts[params[2]]; return value and {{result=value}} or {}
    end
    if sql:find('SELECT id, type',1,true) then return {{id=99,type='item_ammo',instance_mode='stack'}} end
    if sql:find('UPDATE feather_character',1,true) then
        if casFail or params[4] ~= database.revision then return {affectedRows=0} end
        database.pools, database.revision = params[1],params[2]; return {affectedRows=1}
    end
    if sql:find('INSERT INTO feather_ammunition_operations',1,true) then
        if receiptFail then return {affectedRows=0} end
        assert(not database.receipts[params[2]], 'duplicate receipt')
        database.receipts[params[2]]=params[3]; return {affectedRows=1}
    end
    error('unexpected SQL ' .. sql)
end
local tx = { query=query }
function tx:RequireAccess() return noAccess and Result.Err('denied','no access') or nil end
function tx:RemoveQuantity(_, _, amount)
    if database.quantity < amount then return Result.Err('limit','not enough') end
    database.quantity=database.quantity-amount; return Result.Ok({})
end
function tx:AddQuantity(_, _, amount) database.quantity=database.quantity+amount; return Result.Ok({}) end
TransactionAPI = { Transaction=function(_, body)
    local backup=copy(database)
    local ok,result=pcall(body,tx)
    if not ok or not result.ok then database=backup end
    return ok and result or Result.Err('exception',tostring(result))
end }
dofile('server/services/character_ammunition.lua')
local context={actorSource=1,characterId=char,sessionId='session',runtimeEpoch='epoch',runtimeTicket='ticket'}
local function spec(op, amount, revision)
    return {operationId=op,ammunitionId='ammo_repeater_regular',amount=amount,
        expectedRevision=revision,limits={ammo_repeater_regular=200}}
end
local function mutate(value,caller) return CharacterAmmunitionAPI.Mutate(context,value,caller or 'feather-weapons') end
assert(not mutate(spec('one',1,0)).ok, 'disabled by default')
Config.CharacterAmmunitionEnabled=true
assert(not mutate(spec('one',1,0),'foreign').ok)
sessionCurrent=false; assert(not mutate(spec('one',1,0)).ok); sessionCurrent=true
local result=mutate(spec('one',3,0)); assert(result.ok and database.quantity==7 and database.revision==1)
assert(json.decode(database.pools).ammo_repeater_regular==5)
result=mutate(spec('one',3,0)); assert(result.ok and database.quantity==7 and database.revision==1, 'retry must not consume twice')
dofile('server/services/character_ammunition.lua') -- runtime globals rebuilt, mock durable rows survive
result=mutate(spec('one',3,0)); assert(result.ok and database.quantity==7 and database.revision==1, 'receipt survives module reload')
assert(not mutate(spec('one',4,0)).ok, 'same operation different amount')
assert(not mutate(spec('stale',1,0)).ok)
result=mutate(spec('unload',-5,1)); assert(result.ok and database.quantity==12 and database.revision==2)
assert(json.decode(database.pools).ammo_repeater_regular==0)
assert(not mutate(spec('insufficient',-1,2)).ok)
casFail=true; assert(not mutate(spec('cas-fail',1,2)).ok); casFail=false
assert(database.quantity==12 and database.revision==2, 'CAS failure rolls inventory back')
receiptFail=true; assert(not mutate(spec('receipt-fail',1,2)).ok); receiptFail=false
assert(database.quantity==12 and database.revision==2 and not database.receipts['receipt-fail'], 'receipt failure rolls all writes back')
noAccess=true; assert(not mutate(spec('denied',1,2)).ok); noAccess=false
local remove=tx.RemoveQuantity
function tx:RemoveQuantity(...) local result=remove(self,...); sessionCurrent=false; return result end
assert(not mutate(spec('session-changed',1,2)).ok)
assert(database.quantity==12 and database.revision==2, 'session changed before commit rolls back')
print('character ammo atomic boundary PASS (mock transaction)')
-- Real console wrapper and real client/runtime, CFX-shaped callable proxies.
tx.RemoveQuantity=remove; sessionCurrent=true; Config.DevMode=true
database={quantity=0,revision=0,pools=nil,receipts={},enrolled=false}
local legacyQuery=tx.query
tx.query=function(sql,params)
    if sql:find('SELECT revision, pools',1,true) and not database.enrolled then return {} end
    if sql:find('INSERT INTO feather_character',1,true) then
        database.enrolled=true; database.revision=0; database.pools=params[2]; return {affectedRows=1}
    end
    return legacyQuery(sql,params)
end
tx.GetQuantity=function() return database.quantity end
InventoryIdentity.GetCharacter=function() return {char={id=char}} end
InventoryIdentity.GetSession=function() return Result.Ok({characterId=char,sessionId='session'}) end
InventoryControllers={GetInventoryByCharacter=function() return 1 end,InventoryItemCount=function() return database.quantity end}
ItemControllers={GetItemDefinitionByName=function() return {id=99} end}
GuardsAPI={HasRegisteredGuard=function() return false end}
GetResourceState=function(name) return name=='feather-weapons-native-proof' and 'started' or 'stopped' end
DB={exec=function() end,one=function() return database.enrolled and {} or nil end}
dofile('../feather-weapons/shared/character_ammunition.lua')
dofile('../feather-weapons/shared/character_ammunition_runtime.lua')
dofile('../feather-weapons/shared/character_ammunition_client.lua')
local function proxy(value)
    local result={}
    for name,fn in pairs(value) do result[name]=setmetatable({__cfx_functionReference='mock:'..name},
        {__call=function(_,...) return fn(...) end}) end
    return result
end
exports['feather-weapons-native-proof']={CreateInventoryTransferFixture=function(_,validator)
    return {runtime=proxy(WeaponCharacterAmmoRuntime.New(validator)),client=proxy(WeaponCharacterAmmoClient.New())}
end}
local smoke
RegisterCommand=function(_,fn) smoke=fn end
dofile('server/services/character_ammunition.lua')
local originalPrint=print; local output={}; print=function(line) output[#output+1]=line end
smoke(0,{'1','runtime'}); print=originalPrint
local passed=false
for _,line in ipairs(output) do if line:find('done 10/10',1,true) then passed=true end end
assert(passed,table.concat(output,'\n'))
assert(database.quantity==0 and not database.enrolled and next(database.receipts)==nil,
    'economic CFX smoke must roll back quantity, ledger and receipts')
print('economic client/runtime CFX-shaped rollback smoke PASS10/10')
