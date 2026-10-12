local commands={}
RegisterCommand=function(name,fn) commands[name]=fn end
Config={DevMode=true,CharacterAmmunitionEnabled=false}
Result={Codes={CONFLICT='conflict'},Err=function(code,message) return {ok=false,error={code=code,message=message}} end,
    Ok=function(value) return {ok=true,value=value} end,IsOk=function(value) return value and value.ok==true end}
local approved='6a2fd060-c46f-11f1-9ae2-e0d55eaa2deb'
InventoryIdentity={NormalizeCharacterId=function(value) return value==approved and value or nil end,
    GetSession=function() return {ok=true,value={characterId=approved,sessionId='s'}} end}
local current=true
exports={['feather-core']={IsSessionCurrent=function() return current end}}
GetResourceState=function() return 'stopped' end
GuardsAPI={HasRegisteredGuard=function() return false end}
json={encode=function(value) return value end}
local row={id=112,row_revision=0,name='weapon_revolver_cattleman',type='item_weapon',
    metadata={serial='KEEP',serialNumber='KEEP',weaponDefinitionId='revolver_cattleman',ammo={pools={ammo_revolver_regular=0}}}}
local ledger,receipt,equipped=false,false,false
local amount=0
local planner={Build=function() return {validationPassed=true,items={{itemId=112,revision=0,selected='ammo_revolver_regular'}},
    pools={ammo_revolver_regular=amount}} end}
CharacterAmmoCutoverPreview={Load=function() return {},planner,{ammo_revolver_regular=200} end}
local tx={query=function(sql,args)
    if sql:find('SELECT id FROM inventory',1,true) then assert(args[1]==approved); return {{id=5}} end
    if sql:find('FROM inventory_items',1,true) then assert(args[1]==5); return {row} end
    if sql:find('SELECT slot',1,true) then return equipped and {{slot='weapon'}} or {} end
    if sql:find('SELECT revision, pools',1,true) then return ledger and {{revision=0,pools={ammo_revolver_regular=0}}} or {} end
    if sql:find('SELECT result',1,true) then return receipt and {{result=receipt}} or {} end
    if sql:find('INSERT INTO feather_character',1,true) then ledger=true; return {affectedRows=1} end
    if sql:find('INSERT INTO feather_ammunition',1,true) then receipt=args[3]; return {affectedRows=1} end
    error(sql)
end}
tx.SetMetadata=function(_,id,metadata,revision)
    assert(id==112 and revision==0 and metadata.serial=='KEEP' and metadata.ammo.ownership=='character')
    row.metadata=metadata; row.row_revision=1; return Result.Ok({revision=1})
end
dofile('server/services/character_ammunition_enrollment.lua')
local E=CharacterAmmoEnrollment
local catalog,limits={},{ammo_revolver_regular=200}
row.id=1; assert(not E.ApplyJaneTest(tx,catalog,planner,limits).ok and not ledger)
row.id=112; row.row_revision=2; assert(not E.ApplyJaneTest(tx,catalog,planner,limits).ok and not ledger)
row.row_revision=0; amount=1; assert(not E.ApplyJaneTest(tx,catalog,planner,limits).ok and not ledger)
amount=0; equipped=true; assert(not E.ApplyJaneTest(tx,catalog,planner,limits).ok and not ledger)
equipped=false
local enrolled=E.ApplyJaneTest(tx,catalog,planner,limits)
assert(enrolled.ok and enrolled.value.characterId==approved and enrolled.value.itemRevisions['112']==1)
assert(ledger and receipt and row.metadata.serial=='KEEP' and row.metadata.ammo.pools==nil)
assert(not E.ApplyJaneTest(tx,catalog,planner,limits).ok,'retry must not credit or rewrite enrolled item')
assert(E.ReadJaneBaseline(tx).ok,'committed enrollment readback exact')
row.metadata.ammo.loaded=0
assert(not E.ReadJaneBaseline(tx).ok,'even zero per-item ammo forbidden')
row.metadata.ammo.loaded=nil
local savedReceipt=receipt; receipt=nil
assert(not E.ReadJaneBaseline(tx).ok,'missing durable receipt refused')
receipt=savedReceipt; receipt.value.pools.ammo_revolver_regular=1
assert(not E.ReadJaneBaseline(tx).ok,'receipt/pool mismatch refused')
receipt.value.pools.ammo_revolver_regular=0
assert(E.ReadJaneBaseline(tx).ok)
local calls=0
TransactionAPI={Transaction=function(_,body) calls=calls+1; return body(tx) end}
local output={}; local originalPrint=print; print=function(value) output[#output+1]=value end
local run=commands.InvJaneAmmoEnroll
run(1,{'1',approved}); assert(calls==0)
run(0,{'1','original'}); assert(calls==0)
local session=InventoryIdentity.GetSession
InventoryIdentity.GetSession=function() return {ok=true,value={characterId='original',sessionId='s'}} end
run(0,{'1',approved}); assert(calls==0)
InventoryIdentity.GetSession=session; current=false
run(0,{'1',approved}); assert(calls==1 and output[#output]:find('REFUSED',1,true))
Config.CharacterAmmunitionEnabled=true; run(0,{'1',approved}); assert(calls==1)
Config.CharacterAmmunitionEnabled=false; current=true
local query=tx.query
tx.query=function(sql,args) assert(sql:find('SELECT',1,true)==1,'verifier must only read'); return query(sql,args) end
commands.InvJaneAmmoVerify(0,{'1',approved})
assert(calls==2 and output[#output]:find('receiptExact=true metadataExact=true',1,true))
commands.InvJaneAmmoVerify(0,{'1','original'}); assert(calls==2)
print=originalPrint
print('dedicated Jane enrollment PASS (actual Apply, exact item/revision, zero ammo, unequipped, preserved identity, retry/caller/session/gate refusal; mocked SQL)')
