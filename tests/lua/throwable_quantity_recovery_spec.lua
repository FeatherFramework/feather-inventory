-- Actual Inventory observation + quantity recovery bodies; SQL/locks modeled.
local function copy(v) if type(v)~='table' then return v end;local r={};for k,x in pairs(v) do r[k]=copy(x) end;return r end
local function equal(a,b)
 if type(a)~=type(b) then return false end;if type(a)~='table' then return a==b end
 for k,v in pairs(a) do if not equal(v,b[k]) then return false end end
 for k in pairs(b) do if a[k]==nil then return false end end;return true
end
local docs,serial={},0
json={encode=function(v) serial=serial+1;docs[tostring(serial)]=copy(v);return tostring(serial) end,
 decode=function(v) return copy(assert(docs[v])) end}
Result={Codes={INVALID_INPUT='invalid',CONFLICT='conflict',DENIED='denied',NOT_FOUND='missing'},
 Ok=function(v) return {ok=true,value=v} end,Err=function(c,m) return {ok=false,error={code=c,message=m}} end}
Config={CharacterAmmunitionEnabled=true,DevMode=false}
GetConvar=function(name,default) return name=='feather_throwable_quantities' and '1' or default end
RegisterCommand=function() end
InventoryIdentity={NormalizeCharacterId=function(v) return ({jane=true,john=true,third=true})[v] and v end}
InventoryMetadata={DocumentsEqual=equal}
local clock=1000;os.time=function() return clock end
dofile('server/services/character_ammunition.lua')
dofile('server/internal/throwable_quantity_recovery.lua')
local Q=ThrowableQuantityRecovery
local limits={ammo_tomahawk_regular=3,ammo_revolver_regular=100}
local db,queries,failAt,authority,calls
local function reset()
 db={ledgers={jane={revision=0,pools={ammo_tomahawk_regular=3,ammo_revolver_regular=10}},
  john={revision=0,pools={ammo_tomahawk_regular=0,ammo_revolver_regular=7}},
  third={revision=0,pools={ammo_tomahawk_regular=0,ammo_revolver_regular=0}}},allowances={},receipts={}}
 queries=0;failAt=nil;authority=true;calls=0;clock=1000
end
local function current() calls=calls+1;return authority end
local tx={query=function(sql,p)
 queries=queries+1;if queries==failAt then error('interrupted SQL') end
 if sql:find('SELECT id FROM inventory',1,true) then assert(sql:find('FOR UPDATE',1,true));return {{id=1}} end
 if sql:find('SELECT revision, pools',1,true) then
  local l=assert(db.ledgers[p[1]]);return {{revision=l.revision,pools=json.encode(l.pools)}}
 end
 if sql:find('SELECT result_json FROM inventory_grant_receipts',1,true) then
  assert(sql:find('FOR UPDATE',1,true));local r=db.allowances[p[2]];return r and {{result_json=json.encode(r)}} or {}
 end
 if sql:find('INSERT INTO inventory_grant_receipts',1,true) then
  -- Match the actual NOT NULL receipt schema, not merely a JSON row model.
  assert(sql:find('request_fingerprint',1,true) and #p==4)
  assert(type(p[3])=='string' and #p[3]>0 and #p[3]<=300)
  assert(not db.allowances[p[2]]);db.allowances[p[2]]=json.decode(p[4]);return {affectedRows=1}
 end
 if sql:find('SELECT grant_id,result_json',1,true) then
  assert(sql:find('ORDER BY grant_id LIMIT 1 FOR UPDATE',1,true));local rows={}
  for id,v in pairs(db.allowances) do
   if v.bucket==p[2] and v.expiresAt>=p[3] and v.remaining>0
    and (v.position.x-p[4])^2+(v.position.y-p[5])^2+(v.position.z-p[6])^2<=2500 then rows[#rows+1]={grant_id=id,result_json=json.encode(v)} end
  end
  table.sort(rows,function(a,b) return a.grant_id<b.grant_id end);return rows[1] and {rows[1]} or {}
 end
 if sql:find('UPDATE inventory_grant_receipts',1,true) then db.allowances[p[3]]=json.decode(p[1]);return {affectedRows=1} end
 if sql:find('UPDATE feather_character_ammunition',1,true) then
  local l=assert(db.ledgers[p[3]]);if l.revision~=p[4] then return {affectedRows=0} end
  l.pools=json.decode(p[1]);l.revision=p[2];return {affectedRows=1}
 end
 if sql:find('INSERT INTO feather_ammunition_operations',1,true) then
  local key=p[1]..'/'..p[2];assert(not db.receipts[key]);db.receipts[key]=json.decode(p[3]);return {affectedRows=1}
 end
 error('unexpected query '..sql)
end}
local function atomic(fn)
 local before=copy(db);local ok,r=pcall(fn)
 if not ok or not r.ok then db=before end
 return ok and r or Result.Err('interrupted')
end
local function where(x,bucket) return {version=1,bucket=bucket or 0,position={x=x or 0,y=0,z=0}} end
local function spend(units,final)
 local l=db.ledgers.jane
 return atomic(function() return CharacterAmmunitionAPI.ApplyObservation(tx,{characterId='jane'},
  {expectedRevision=l.revision,pools={ammo_tomahawk_regular=l.pools.ammo_tomahawk_regular-units,
   ammo_revolver_regular=l.pools.ammo_revolver_regular},limits=limits,quantityRecovery=where(),finalWear=final},current) end)
end
local function claim(character,position,revision,pools)
 local l=db.ledgers[character];local after=pools or copy(l.pools);if not pools then after.ammo_tomahawk_regular=after.ammo_tomahawk_regular+1 end
 return atomic(function() return Q.Claim(tx,{characterId=character},
  {expectedRevision=revision or l.revision,pools=after,limits=limits,
   nativePickupPlan={version=2,kind='quantity_pickup_ledger_plan',location=position or where()}},current) end)
end
reset();assert(spend(1).ok and db.ledgers.jane.pools.ammo_tomahawk_regular==2)
assert(db.allowances['jane:0'].remaining==1 and db.allowances['jane:0'].units==1)
local recorded=copy(db.allowances)
local r=claim('john');assert(r.ok and r.value.recovered==1 and not r.value.quantityDeclined)
assert(db.ledgers.john.pools.ammo_tomahawk_regular==1 and db.allowances['jane:0'].remaining==0)
local old=copy(db);assert(not claim('john',nil,0).ok and equal(db,old),'old report cannot claim twice')
r=claim('third');assert(r.ok and r.value.quantityDeclined and db.ledgers.third.pools.ammo_tomahawk_regular==0)
assert(db.ledgers.jane.pools.ammo_tomahawk_regular+db.ledgers.john.pools.ammo_tomahawk_regular==3)
assert(db.allowances['jane:0'].serialNumber==nil and db.allowances['jane:0'].itemId==nil,'allowance has no item metadata')
reset();assert(spend(3).ok)
for _=1,3 do assert(claim('john').value.recovered==1) end
assert(not claim('john').ok,'ceiling3')
assert(claim('third').value.quantityDeclined and db.allowances['jane:0'].remaining==0,'competing collector cannot exceed funded budget')
reset();assert(spend(3).ok)
r=claim('john',nil,nil,{ammo_tomahawk_regular=3,ammo_revolver_regular=7})
assert(r.ok and r.value.recovered==3 and not r.value.quantityDeclined and db.allowances['jane:0'].remaining==0,
 'several native pickups in one sample consume quantities atomically')
reset();assert(spend(2).ok)
r=claim('john',nil,nil,{ammo_tomahawk_regular=3,ammo_revolver_regular=6})
assert(r.ok and r.value.recovered==2 and r.value.quantityDeclined and r.value.pools.ammo_tomahawk_regular==2
 and r.value.pools.ammo_revolver_regular==6,'partial funded batch preserves funded units and shot reductions')
reset();assert(spend(1).ok);assert(claim('jane').value.recovered==1,'same-player recovery uses the same allowance')
for _,scenario in ipairs({'bucket','distance','expired'}) do
 reset();assert(spend(1).ok)
 local position=where(scenario=='distance' and 50.01 or 0,scenario=='bucket' and 1 or 0)
 if scenario=='expired' then clock=1181 end
 assert(claim('john',position).value.quantityDeclined and db.allowances['jane:0'].remaining==1,scenario)
 assert(db.ledgers.john.pools.ammo_tomahawk_regular==0)
end
reset();assert(spend(1).ok and claim('john',where(50)).value.recovered==1,'inclusive radius50m')
reset();r=claim('john',nil,nil,{ammo_tomahawk_regular=1,ammo_revolver_regular=6})
assert(r.ok and r.value.quantityDeclined and db.ledgers.john.pools.ammo_revolver_regular==6
 and db.ledgers.john.pools.ammo_tomahawk_regular==0,'denial keeps genuine shot reductions')
reset();assert(not claim('john',nil,nil,{ammo_tomahawk_regular=1,ammo_revolver_regular=8}).ok,'no firearm increases')
reset();assert(spend(1,{characterId='jane'}).ok and next(db.allowances)==nil,'final/death seal cannot create recovery budget')
reset();authority=false;local old=copy(db);assert(not spend(1).ok and equal(old,db))
reset();assert(spend(1).ok);queries=0;assert(claim('john').ok);local claimQueries=queries
for n=1,claimQueries do
 reset();assert(spend(1).ok);queries=0;failAt=n;local before=copy(db)
 assert(not claim('john').ok and equal(before,db),'claim rollback at query'..n)
end
reset();assert(spend(1).ok);local spendQueries=queries
for n=1,spendQueries do
 reset();failAt=n;local before=copy(db);assert(not spend(1).ok and equal(before,db),'debit and allowance roll back together'..n)
end
print('PASS quantity recovery: actual debit/claim bodies, shared/same-player conservation, bounded lifetime/radius/bucket, ceiling, denial without refunds, modeled SQL locks and atomic rollback')
