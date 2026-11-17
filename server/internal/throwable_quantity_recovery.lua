-- Internal transaction primitive. Quantities only; no projectile, item serial,
-- native GUID or original item metadata is transferred through world pickups.
-- Caller owns rollback and validates the exact server runtime reservation.
ThrowableQuantityRecovery={}
local Q=ThrowableQuantityRecovery
local namespace='tomahawk-quantity-allowance-v1'
local function int(v,min,max) return type(v)=='number' and v%1==0 and v>=min and v<=max end
local function copy(v) if type(v)~='table' then return v end;local r={};for k,x in pairs(v) do r[k]=copy(x) end;return r end
local function decode(v) local ok,r=pcall(json.decode,v);return ok and type(r)=='table' and r or nil end
local function denied(code) return Result.Err(code or 'quantity_recovery_refused','Quantity recovery reservation or balance changed.') end
local function location(v)
 if type(v)~='table' or v.version~=1 or not int(v.bucket,0,2147483647) or type(v.position)~='table' then return false end
 for _,k in ipairs({'x','y','z'}) do local n=v.position[k];if type(n)~='number' or n~=n or math.abs(n)>10000000 then return false end end
 return true
end
local function live(current)
 local callable=type(current)=='function' or type(current)=='table' and type(rawget(current,'__cfx_functionReference'))=='string'
 if not callable then return false end;local ok,v=pcall(current);return ok and v==true
end
local function wrote(v) return type(v)=='table' and tonumber(v.affectedRows)==1 end
local function record(tx,context,spec,previous,observed,current,ammoId,cap,namespace,kind)
 local where=spec.quantityRecovery
 local before,after=previous[ammoId],observed[ammoId]
 local units=type(before)=='number' and type(after)=='number' and before-after or 0
 if spec.finalWear~=nil or not location(where) or not int(units,1,cap) or not int(spec.expectedRevision,0,9007199254740990)
  or spec.limits[ammoId]~=cap or not live(current) then return denied() end
 if ammoId~='ammo_tomahawk_regular' and (where.bucketTest~=nil or where.distanceTestOffset~=nil or where.expiryTestSeconds~=nil) then return denied() end
 local lifetime=180
 if where.bucketTest~=nil then
  if where.bucketTest~=true or units~=1 or where.expiryTestSeconds~=nil or where.distanceTestOffset~=nil
   or type(GetConvar)~='function' or GetConvar('feather_quantity_bucket_test','0')~='1' then return denied() end
 end
 if where.distanceTestOffset~=nil then
  if where.distanceTestOffset~=100 or units~=1 or where.expiryTestSeconds~=nil or type(GetConvar)~='function'
   or GetConvar('feather_quantity_distance_test','0')~='1' then return denied() end
 end
 if where.expiryTestSeconds~=nil then
  if where.expiryTestSeconds~=5 or units~=1 or type(GetConvar)~='function'
   or GetConvar('feather_quantity_expiry_test','0')~='1' then return denied() end
  lifetime=5
 end
 local id=context.characterId..':'..spec.expectedRevision
 local rows=tx.query('SELECT result_json FROM inventory_grant_receipts WHERE source_resource=? AND grant_id=? FOR UPDATE',{namespace,id})
 if type(rows)~='table' or #rows~=0 then return denied() end
 local now=os.time()
 local value={version=1,kind=kind,remaining=units,units=units,
  bucket=where.bucket,position=copy(where.position),createdAt=now,expiresAt=now+lifetime,
  expiryTest=lifetime==5 or nil}
 if where.distanceTestOffset==100 then
  value.position.x=value.position.x+100;value.distanceTest=true
 end
 if where.bucketTest==true then
  value.bucket=where.bucket==2147483647 and 0 or where.bucket+1;value.bucketTest=true
 end
 local fingerprint=('quantity-v1:%s:%d:%d'):format(id,units,where.bucket)
 if not wrote(tx.query('INSERT INTO inventory_grant_receipts (source_resource,grant_id,request_fingerprint,result_json) VALUES (?,?,?,?)',
  {namespace,id,fingerprint,json.encode(value)})) or not live(current) then return denied() end
 return Result.Ok({units=units})
end
function Q.Record(tx,context,spec,previous,observed,current)
 local total=0
 for _,profile in ipairs({
  {'ammo_tomahawk_regular',3,'tomahawk-quantity-allowance-v1','tomahawk_quantity_allowance','feather_throwable_quantities'},
  {'ammo_arrow_regular',40,'regular-arrow-quantity-allowance-v1','regular_arrow_quantity_allowance','feather_regular_arrows'},
 }) do
  local id,cap,ns,kind,flag=table.unpack(profile)
  if type(previous[id])=='number' and type(observed[id])=='number' and previous[id]>observed[id] then
   if id=='ammo_arrow_regular' and (type(GetConvar)~='function' or GetConvar(flag,'0')~='1') then return denied() end
   local result=record(tx,context,spec,previous,observed,current,id,cap,ns,kind)
   if not result.ok then return result end
   total=total+result.value.units
  end
 end
 if total==0 then return denied() end
 return Result.Ok({units=total})
end
function Q.Claim(tx,context,spec,current)
 local plan=spec.nativePickupPlan
 local ammoId=type(plan)=='table' and plan.ammunitionId or 'ammo_tomahawk_regular'
 local cap,kind=3,'tomahawk_quantity_allowance'
 local namespace=namespace
 if ammoId=='ammo_arrow_regular' then
  if type(GetConvar)~='function' or GetConvar('feather_regular_arrows','0')~='1' then return denied() end
  cap,kind,namespace=40,'regular_arrow_quantity_allowance','regular-arrow-quantity-allowance-v1'
 elseif ammoId~='ammo_tomahawk_regular' then return denied() end
 if type(plan)~='table' or plan.version~=2 or plan.kind~='quantity_pickup_ledger_plan' or not location(plan.location)
  or spec.limits[ammoId]~=cap or not int(spec.expectedRevision,0,9007199254740990)
  or type(spec.pools)~='table' or not live(current) then return denied() end
 local ledger=CharacterAmmunitionAPI.ReadSnapshot(tx,context.characterId,spec.limits,false)
 if not ledger or not ledger.ok then return ledger or denied() end
 local previous=ledger.value.pools
 local requested=type(spec.pools[ammoId])=='number' and spec.pools[ammoId]-previous[ammoId] or 0
 if ledger.value.revision~=spec.expectedRevision or not int(previous[ammoId],0,cap-1)
  or not int(requested,1,cap) then return denied() end
 for id,n in pairs(previous) do if id~=ammoId and (type(spec.pools[id])~='number' or spec.pools[id]>n) then return denied() end end
 for id,n in pairs(spec.pools) do if previous[id]==nil or not int(n,0,spec.limits[id] or -1) then return denied() end end
 -- Deterministic nearby row lock serializes competing claims. Each paid
 -- allowance is consumed once; proximity is deliberately NOT object identity.
 local recovered=0
 for _=1,cap do
  if recovered==requested then break end
  local rows=tx.query([[SELECT grant_id,result_json FROM inventory_grant_receipts
  WHERE source_resource=? AND JSON_EXTRACT(result_json,'$.bucket')=?
   AND JSON_EXTRACT(result_json,'$.expiresAt')>=? AND JSON_EXTRACT(result_json,'$.remaining')>0
   AND POW(JSON_EXTRACT(result_json,'$.position.x')-?,2)
     + POW(JSON_EXTRACT(result_json,'$.position.y')-?,2)
     + POW(JSON_EXTRACT(result_json,'$.position.z')-?,2)<=2500
  ORDER BY grant_id LIMIT 1 FOR UPDATE]],{namespace,plan.location.bucket,os.time(),
   plan.location.position.x,plan.location.position.y,plan.location.position.z})
  if type(rows)~='table' or #rows>1 then return denied() end
  if #rows==0 then break end
  local row=rows[1]
  local v=decode(row.result_json)
  if not v or v.version~=1 or v.kind~=kind or not location({version=1,bucket=v.bucket,position=v.position})
   or not int(v.units,1,cap) or not int(v.remaining,1,v.units) or not int(v.createdAt,0,9007199254740990)
   or (v.expiryTest~=nil and v.expiryTest~=true)
   or (v.expiryTest==true and v.units~=1)
   or (v.distanceTest~=nil and v.distanceTest~=true)
   or (v.distanceTest==true and (v.units~=1 or v.expiryTest~=nil))
   or (v.bucketTest~=nil and v.bucketTest~=true)
   or (v.bucketTest==true and (v.units~=1 or v.expiryTest~=nil or v.distanceTest~=nil))
   or v.expiresAt~=v.createdAt+(v.expiryTest==true and 5 or 180) or type(row.grant_id)~='string' then return denied() end
  local a,b=v.position,plan.location.position
  if v.bucket~=plan.location.bucket or v.expiresAt<os.time()
   or (a.x-b.x)^2+(a.y-b.y)^2+(a.z-b.z)^2>2500 or not live(current) then return denied() end
  local taken=math.min(requested-recovered,v.remaining)
  v.remaining=v.remaining-taken
  if not wrote(tx.query('UPDATE inventory_grant_receipts SET result_json=? WHERE source_resource=? AND grant_id=?',
   {json.encode(v),namespace,row.grant_id})) then return denied() end
  recovered=recovered+taken
 end
 if not live(current) then return denied() end
 -- Keep genuine shot reductions and any funded portion of a batched pickup.
 local accepted=copy(spec.pools);accepted[ammoId]=previous[ammoId]+recovered
 if not wrote(tx.query('UPDATE feather_character_ammunition SET pools=?,revision=? WHERE character_id=? AND revision=?',
  {json.encode(accepted),spec.expectedRevision+1,context.characterId,spec.expectedRevision})) or not live(current) then return denied() end
 local value={characterId=context.characterId,revision=spec.expectedRevision+1,pools=accepted,recovered=recovered,
  quantityDeclined=recovered<requested}
 local id='quantity-pickup:'..spec.expectedRevision
 if not wrote(tx.query('INSERT INTO feather_ammunition_operations (character_id,operation_id,result) VALUES (?,?,?)',
  {context.characterId,id,json.encode({kind='quantity_pickup_receipt',value=value})})) then return denied() end
 return Result.Ok(value)
end
