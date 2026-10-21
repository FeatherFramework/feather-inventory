-- Actual export/final-wear/assigned-carrier/funding/ledger bodies; mocked SQL
-- transaction and access ports. This is not live native or DB contention proof.
local function copy(v) if type(v)~='table' then return v end; local r={}; for k,x in pairs(v) do r[k]=copy(x) end; return r end
local function equal(a,b)
 if type(a)~=type(b) then return false end; if type(a)~='table' then return a==b end
 for k,v in pairs(a) do if not equal(v,b[k]) then return false end end
 for k in pairs(b) do if a[k]==nil then return false end end; return true
end
local docs,seq={},0
json={encode=function(v) seq=seq+1; docs[tostring(seq)]=copy(v); return tostring(seq) end,
 decode=function(v) return copy(assert(docs[v])) end}
Result={Codes={CONFLICT='conflict',INVALID_INPUT='invalid',NOT_FOUND='missing',LIMIT_EXCEEDED='limit'},
 Ok=function(v) return {ok=true,value=v} end,Err=function(c,m) return {ok=false,error={code=c,message=m}} end,
 IsOk=function(r) return r and r.ok end}
IsCallable=nil
InventoryMetadata={DocumentsEqual=equal}
InventoryIdentity={NormalizeCharacterId=function(v) return v=='john' and v or nil end}
InventoryAPI={AccessModes={REMOVE='remove',INSERT='insert'}}
Config={DevMode=true,CharacterAmmunitionEnabled=true}
RegisterCommand=function() end
local current,flag,failCAS,failReceipt,lose=true,1,false,false,false
local registered={}
GetInvokingResource=function() return 'feather-weapons' end
GetConvarInt=function(name) return (name=='feather_native_throwable_pickup' or name=='feather_native_utility') and 0 or flag end
GetResourceState=function() return 'started' end
exports=setmetatable({['feather-core']={IsSessionCurrent=function() return current end},
 ['feather-weapons']={ValidateNativeEquipmentCommit=function(_,ctx,spec)
  return current and ctx.ticket=='released' and spec.operationId~=nil
 end}}, {__call=function(_,n,f) registered[n]=f end})
local metadata={schemaVersion=2,weaponDefinitionId='throwable_tomahawk',serialNumber='T',condition=100,
 ammo={ownership='character',type='ammo_tomahawk_regular'},flags={disabled=false,evidence=false}}
local db={revision=0,pools={ammo_tomahawk_regular=0,ammo_repeater_regular=1},loose=2,receipts={},assigned=170}
local tx={}
function tx.query(sql,p)
 if sql:find('SELECT id FROM inventory',1,true) then return {{id=5}} end
 if sql:find('SELECT revision, pools',1,true) then return {{revision=db.revision,pools=json.encode(db.pools)}} end
 if sql:find('SELECT ce.slot',1,true) then return {{slot='weapon_throwable',inventory_items_id=db.assigned,row_revision=0,owner_character='john'}} end
 if sql:find('SELECT ii.id',1,true) then return {{id=db.assigned,row_revision=0,itemName='weapon_thrown_tomahawk',metadata=copy(metadata)}} end
 if sql:find('SELECT result FROM',1,true) then return db.receipts[p[2]] and {{result=db.receipts[p[2]]}} or {} end
 if sql:find('SELECT id, type',1,true) then return {{id=10,type='item_ammo',instance_mode='stack'}} end
 if sql:find('UPDATE feather_character',1,true) then
  if failCAS or db.revision~=p[4] then return {affectedRows=0} end
  db.revision=p[2]; db.pools=json.decode(p[1]); if lose then current=false end
  return {affectedRows=1}
 end
 if sql:find('INSERT INTO feather_ammunition',1,true) then
  if failReceipt then return {affectedRows=0} end
  db.receipts[p[2]]=p[3]; return {affectedRows=1}
 end
 error(sql)
end
function tx:RequireAccess() return nil end
function tx:RemoveQuantity(_,id,n)
 assert(id==10); if db.loose<n then return Result.Err('insufficient','no loose ammo') end
 db.loose=db.loose-n; return Result.Ok({})
end
function tx:AddQuantity(_,id,n) assert(id==10); db.loose=db.loose+n; return Result.Ok({}) end
TransactionAPI={Transaction=function(_,fn)
 local before=copy(db); local ok,r=pcall(fn,tx)
 if not ok or not r.ok then db=before end
 if not ok then error(r) end; return r
end}
for _,p in ipairs({'server/services/character_ammunition.lua','server/services/native_knife_equipment.lua',
 'server/services/native_lifecycle_wear.lua','server/services/native_equipment_commit.lua'}) do dofile(p) end
local context={actorSource=7,characterId='john',sessionId='s',epoch='e',ticket='released'}
local function spec(amount,key)
 return {characterId='john',action='throwable-funding',throwable=true,slot='weapon_throwable',
  throwableId=170,throwableRevision=0,before=copy(metadata),expected={weapon_throwable={itemId=170,revision=0}},
  lifecycleSnapshot={},lifecycleWear={},limits={ammo_tomahawk_regular=1,ammo_repeater_regular=200},
  expectedRevision=db.revision,expectedPools=copy(db.pools),ammunitionId='ammo_tomahawk_regular',amount=amount,operationId=key}
end
local commit=registered.CommitNativeThrowableFunding
local original=spec(1,'fund-v1')
context.ticket='active'; assert(not commit(context,original).ok and db.loose==2); context.ticket='released'
for _,mode in ipairs({'cas','receipt','authority','assignment'}) do
 local before=copy(db)
 failCAS=mode=='cas'; failReceipt=mode=='receipt'; lose=mode=='authority'
 if mode=='assignment' then db.assigned=171; before.assigned=171 end
 assert(not commit(context,original).ok and equal(db,before),'all economic writes roll back: '..mode)
 current=true; failCAS=false; failReceipt=false; lose=false; db.assigned=170
end
assert(commit(context,original).ok and db.loose==1 and db.revision==1 and db.pools.ammo_tomahawk_regular==1)
assert(not commit(context,original).ok and db.loose==1,'lost-reply stale retry cannot charge twice')
assert(not commit(context,spec(1,'overfill')).ok and db.loose==1)
assert(commit(context,spec(-1,'unfund-v1')).ok and db.loose==2 and db.revision==2 and db.pools.ammo_tomahawk_regular==0)
assert(commit(context,spec(1,'fund-v2')).ok and db.loose==1 and db.revision==3)
local observation={expectedRevision=3,limits=original.limits,pools={ammo_tomahawk_regular=0,ammo_repeater_regular=1}}
assert(TransactionAPI.Transaction({},function(t) return CharacterAmmunitionAPI.ApplyObservation(t,context,observation) end).ok)
assert(db.revision==4 and db.loose==1 and db.pools.ammo_tomahawk_regular==0)
assert(not commit(context,spec(1,'fund-v2')).ok and db.loose==1,'receipt reuse after consumption cannot replenish')
assert(db.pools.ammo_repeater_regular==1 and db.assigned==170)
print('throwable atomic funding PASS: real export/wear/assignment/ledger/payment/receipt, fund/unfund/spend, rollback and no replay replenishment; mocked SQL')
