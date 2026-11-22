-- Execute the real observation/recovery primitives; model SQL locks and rollback.
local knives=arg and arg[2]=='knives'
local ammoId=knives and 'ammo_throwing_knives_regular' or 'ammo_arrow_regular'
local capacity=knives and 8 or 40
local flag=knives and 'feather_throwing_knife_quantities' or 'feather_regular_arrows'
local namespace=knives and 'regular-knife-quantity-allowance-v1' or 'regular-arrow-quantity-allowance-v1'
local function copy(v) if type(v)~='table' then return v end;local r={};for k,x in pairs(v) do r[k]=copy(x) end;return r end
local docs,serial={},0
json={encode=function(v) serial=serial+1;docs[tostring(serial)]=copy(v);return tostring(serial) end,
 decode=function(v) return copy(assert(docs[v])) end}
Result={Codes={INVALID_INPUT='invalid',CONFLICT='conflict',DENIED='denied',NOT_FOUND='missing'},
 Ok=function(v) return {ok=true,value=v} end,Err=function(c) return {ok=false,error={code=c}} end}
Config={CharacterAmmunitionEnabled=true,DevMode=false}
local enabled=true
local extraFlags={}
GetConvar=function(name,default) return extraFlags[name] or name==flag and enabled and '1'
 or name=='feather_throwable_quantities' and '1' or default end
RegisterCommand=function() end
InventoryIdentity={NormalizeCharacterId=function(v) return v end}
local clock=1000;os.time=function() return clock end
dofile('server/services/character_ammunition.lua');dofile('server/internal/throwable_quantity_recovery.lua')
local limits={[ammoId]=capacity,ammo_tomahawk_regular=3,ammo_revolver_regular=100}
local db,failUpdate,authority
local function reset()
 db={ledgers={jane={revision=0,pools={[ammoId]=capacity,ammo_tomahawk_regular=3,ammo_revolver_regular=10}},
  john={revision=0,pools={[ammoId]=0,ammo_tomahawk_regular=0,ammo_revolver_regular=7}}},allowances={},receipts={}}
 clock=1000;enabled=true;failUpdate=false;authority=true
end
local function key(ns,id) return ns..'/'..id end
local tx={query=function(sql,p)
 if sql:find('SELECT id FROM inventory',1,true) then return {{id=1}} end
 if sql:find('SELECT revision, pools',1,true) then local l=db.ledgers[p[1]];return {{revision=l.revision,pools=json.encode(l.pools)}} end
 if sql:find('SELECT result_json FROM inventory_grant_receipts',1,true) then local r=db.allowances[key(p[1],p[2])];return r and {{result_json=json.encode(r)}} or {} end
 if sql:find('INSERT INTO inventory_grant_receipts',1,true) then
  assert(sql:find('request_fingerprint',1,true) and #p==4);local k=key(p[1],p[2]);assert(not db.allowances[k]);db.allowances[k]=json.decode(p[4]);return {affectedRows=1}
 end
 if sql:find('SELECT grant_id,result_json',1,true) then
  assert(sql:find('ORDER BY grant_id LIMIT 1 FOR UPDATE',1,true));local rows={}
  for k,v in pairs(db.allowances) do
   local ns,id=k:match('^(.-)/(.*)$')
   if ns==p[1] and v.bucket==p[2] and v.expiresAt>=p[3] and v.remaining>0
    and (v.position.x-p[4])^2+(v.position.y-p[5])^2+(v.position.z-p[6])^2<=2500 then
    rows[#rows+1]={grant_id=id,result_json=json.encode(v)}
   end
  end
  table.sort(rows,function(a,b) return a.grant_id<b.grant_id end);return rows[1] and {rows[1]} or {}
 end
 if sql:find('UPDATE inventory_grant_receipts',1,true) then db.allowances[key(p[2],p[3])]=json.decode(p[1]);return {affectedRows=1} end
 if sql:find('UPDATE feather_character_ammunition',1,true) then
  if failUpdate then error('injected database failure') end
  local l=db.ledgers[p[3]];if l.revision~=p[4] then return {affectedRows=0} end
  l.pools=json.decode(p[1]);l.revision=p[2];return {affectedRows=1}
 end
 if sql:find('INSERT INTO feather_ammunition_operations',1,true) then local k=key(p[1],p[2]);assert(not db.receipts[k]);db.receipts[k]=json.decode(p[3]);return {affectedRows=1} end
 error('unexpected SQL: '..sql)
end}
local function current() return authority end
local function atomic(fn)
 local before=copy(db);local ok,r=pcall(fn)
 if not ok or not r.ok then db=before end
 return ok and r or Result.Err('interrupted')
end
local function where(x,bucket) return {version=1,bucket=bucket or 0,position={x=x or 0,y=0,z=0}} end
local function spend(arrows,toms)
 local l=db.ledgers.jane;local p=copy(l.pools);p[ammoId]=p[ammoId]-arrows;p.ammo_tomahawk_regular=p.ammo_tomahawk_regular-(toms or 0)
 return atomic(function() return CharacterAmmunitionAPI.ApplyObservation(tx,{characterId='jane'},
  {expectedRevision=l.revision,pools=p,limits=limits,quantityRecovery=where()},current) end)
end
local function claim(id,n,position,revision)
 local l=db.ledgers.john;local p=copy(l.pools);p[id]=p[id]+n
 return atomic(function() return ThrowableQuantityRecovery.Claim(tx,{characterId='john'},
  {expectedRevision=revision or l.revision,pools=p,limits=limits,
   nativePickupPlan={version=2,kind='quantity_pickup_ledger_plan',ammunitionId=id,location=position or where()}},current) end)
end
if arg and arg[3]=='fixture' then
 return {reset=reset,db=function() return db end,limits=limits,tx=tx,copy=copy,atomic=atomic,current=current,
  where=where,claim=claim,spend=spend,flags=extraFlags,fail=function(v) failUpdate=v end}
end
reset();assert(spend(3,1).ok)
assert(db.ledgers.jane.pools[ammoId]==capacity-3 and db.ledgers.jane.pools.ammo_tomahawk_regular==2)
assert(db.allowances[namespace..'/jane:0'].remaining==3)
assert(db.allowances['tomahawk-quantity-allowance-v1/jane:0'].remaining==1,'same revision has type-separated receipts')
local r=claim(ammoId,4);assert(r.ok and r.value.recovered==3 and r.value.quantityDeclined)
assert(db.ledgers.john.pools[ammoId]==3 and db.ledgers.john.pools.ammo_tomahawk_regular==0)
assert(db.allowances['tomahawk-quantity-allowance-v1/jane:0'].remaining==1,'arrows cannot consume Tomahawk allowances')
r=claim(ammoId,1);assert(r.ok and r.value.recovered==0,'spent allowance cannot be reused')
assert(claim('ammo_tomahawk_regular',1).value.recovered==1)
reset();assert(spend(capacity).ok);r=claim(ammoId,capacity);assert(r.ok and r.value.recovered==capacity)
assert(not claim(ammoId,1).ok,'capacity cannot exceed40')
reset();assert(spend(1).ok);assert(claim(ammoId,1,where(51)).value.recovered==0)
assert(claim(ammoId,1,where(0,1)).value.recovered==0)
clock=1181;assert(claim(ammoId,1).value.recovered==0)
reset();assert(spend(1).ok);failUpdate=true;assert(not claim(ammoId,1).ok)
assert(db.allowances[namespace..'/jane:0'].remaining==1 and db.ledgers.john.revision==0,'SQL failure rolls back allowance and ledger')
reset();failUpdate=true;assert(not spend(1).ok);assert(next(db.allowances)==nil and db.ledgers.jane.pools[ammoId]==capacity,'debit and allowance creation roll back together')
reset();assert(spend(1).ok);enabled=false;assert(not claim(ammoId,1).ok)
reset();assert(spend(1).ok);authority=false;assert(not claim(ammoId,1).ok)
reset();assert(spend(1).ok);assert(not claim(ammoId,1,nil,99).ok)
print('PASS '..ammoId..' SQL composition: atomic paid debits, distinct type namespaces, bounded batches/partial credit, once-only claims, expiry/distance/bucket, capacity, authority, stale revisions and rollback')
