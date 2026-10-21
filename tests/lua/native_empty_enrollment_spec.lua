local root=arg and arg[1] or '.'
local function copy(v) if type(v)~='table' then return v end; local t={}; for k,x in pairs(v) do t[k]=copy(x) end; return t end
Result={Codes={CONFLICT='conflict'},Ok=function(v) return {ok=true,value=v} end,Err=function(c,m) return {ok=false,error={code=c,message=m}} end}
InventoryIdentity={NormalizeCharacterId=function(v) return v=='John' and v or nil end}
local commands={}; RegisterCommand=function(name,fn) commands[name]=fn end
local docs,n={},0
json={encode=function(v) n=n+1; docs[tostring(n)]=copy(v); return tostring(n) end,decode=function(v) return copy(docs[v]) end}
dofile(root..'/server/services/character_ammunition_enrollment.lua')
local db,current,failReceipt,changeAfterInsert,missing
local function reset() db={items={},equipment={},ledger=nil,receipt=nil}; current=true; failReceipt=false; changeAfterInsert=false; missing=false end
local tx={query=function(sql,p)
 assert(p[1]=='John' or p[1]==7,'only target rows may be touched')
 if sql:find('SELECT id FROM inventory ',1,true) then return missing and {} or {{id=7}} end
 if sql:find('FROM inventory_items',1,true) then return copy(db.items) end
 if sql:find('FROM character_equipment',1,true) then return copy(db.equipment) end
 if sql:find('SELECT revision, pools',1,true) then return db.ledger and {db.ledger} or {} end
 if sql:find('SELECT result',1,true) then return db.receipt and {{result=db.receipt}} or {} end
 if sql:find('INSERT INTO feather_character',1,true) then
  db.ledger={revision=0,pools=p[2]}; if changeAfterInsert then current=false end; return {affectedRows=1}
 end
 if sql:find('INSERT INTO feather_ammunition',1,true) then
  if failReceipt then return {affectedRows=0} end; db.receipt=p[3]; return {affectedRows=1}
 end
 error(sql)
end,SetMetadata=function() error('empty enrollment must never rewrite items') end}
local planner={Build=function(items) assert(#items==0); return {validationPassed=true,items={},pools={ammo=0}} end}
local function apply()
 local before=copy(db)
 local result=CharacterAmmoEnrollment.ApplyEmpty(tx,'John',{},planner,{ammo=20},function() return current end)
 if not result.ok then db=before end
 return result
end
reset(); assert(apply().ok and db.ledger.revision==0 and docs[db.ledger.pools].ammo==0 and db.receipt)
assert(not apply().ok,'repeated initialization cannot reset ledger or rewrite receipt')
reset(); db.items={{id=1}}; assert(not apply().ok and not db.ledger)
reset(); db.equipment={{slot='weapon'}}; assert(not apply().ok and not db.ledger)
reset(); missing=true; assert(not apply().ok)
reset(); failReceipt=true; assert(not apply().ok and not db.ledger,'receipt failure rolls back ledger')
reset(); changeAfterInsert=true; assert(not apply().ok and not db.ledger,'lost authority rolls back writes')
reset(); current=false; assert(not apply().ok and not db.ledger)
Config={DevMode=true}; local printed=0; local oldPrint=print; print=function() printed=printed+1 end
GetResourceState=function() return 'started' end
GuardsAPI={HasRegisteredGuard=function() return false end}; GetConvar=function() return 'John' end
commands.InvNativeEmptyAmmoEnroll(1,{'6','John'}); assert(printed==0,'player invocation ignored')
commands.InvNativeEmptyAmmoEnroll(0,{'6','John'}); assert(printed==1,'running Weapons refuses before session/SQL')
print=oldPrint
print('Empty native enrollment PASS (canonical ledger+receipt, zero ammo, no item writes, existing/missing/authority refusal, rollback; mocked SQL)')
