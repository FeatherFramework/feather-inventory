function RegisterCommand() end
local make = assert(loadfile('server/services/character_ammunition_replay_test.lua'))()
Result = { Codes={LIMIT_EXCEEDED='limit',CONFLICT='conflict'},
    Ok=function(value) return {ok=true,value=value} end,
    Err=function(code) return {ok=false,error={code=code}} end }
local calls={}
local tx=make({query=function(sql,params)
    calls[#calls+1]={sql=sql,params=params}
    assert(not sql:find('feather_character_ammunition',1,true))
    assert(not sql:find('feather_ammunition_operations',1,true))
    assert(not sql:find('inventory_items',1,true))
    assert(sql:find('fi_ammo_smoke_',1,true))
    return {affectedRows=1}
end})
local id='00000000-0000-4000-8000-000000000001'
tx.query('SELECT id FROM inventory WHERE character_id = ? LIMIT 1 FOR UPDATE',{id})
tx.query('SELECT revision, pools FROM feather_character_ammunition WHERE character_id = ? FOR UPDATE',{id})
tx.query('SELECT result FROM feather_ammunition_operations WHERE character_id = ? AND operation_id = ? FOR UPDATE',{id,'one'})
tx.query('UPDATE feather_character_ammunition SET pools = ?, revision = ? WHERE character_id = ? AND revision = ?',{'json',1,id,0})
tx.query('INSERT INTO feather_ammunition_operations (character_id, operation_id, result) VALUES (?, ?, ?)',{id,'one','json'})
assert(tx:RemoveQuantity(1,1,3).ok)
assert(tx:AddQuantity(1,1,3).ok)
assert(not pcall(tx.query,'DELETE FROM inventory_items WHERE id = ?',{1}))
assert(not pcall(tx.query,'SELECT * FROM items',{}))
local definition=tx.query('SELECT id, type, instance_mode, archived_at FROM items WHERE name = ? LIMIT 1',{'ammo_repeater_regular'})
assert(definition[1].type=='item_ammo' and #calls==7)
print('character ammo fixture SQL isolation PASS')
