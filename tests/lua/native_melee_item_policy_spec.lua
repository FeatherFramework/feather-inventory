local root=arg[1]
Config={CharacterAmmunitionEnabled=true}
local calls=0
DB={exec=function(sql,...)
 calls=calls+1
 assert(sql:find('UPDATE items SET usable=0',1,true))
 assert(sql:find("type='item_weapon'",1,true) and sql:find("instance_mode='unique'",1,true))
 local names={...};assert(#names==30)
 local expected={["weapon_thrown_tomahawk"]=true,["weapon_melee_cleaver"]=true,["weapon_melee_hammer"]=true,["weapon_melee_hatchet"]=true,["weapon_melee_knife"]=true,["weapon_melee_machete"]=true,["weapon_pistol_m1899"]=true,["weapon_pistol_mauser"]=true,["weapon_pistol_semiauto"]=true,["weapon_pistol_volcanic"]=true,["weapon_repeater_carbine"]=true,["weapon_repeater_evans"]=true,["weapon_repeater_henry"]=true,["weapon_repeater_lancaster"]=true,["weapon_revolver_cattleman"]=true,["weapon_revolver_doubleaction"]=true,["weapon_revolver_lemat"]=true,["weapon_revolver_navy"]=true,["weapon_revolver_schofield"]=true,["weapon_rifle_boltaction"]=true,["weapon_rifle_elephant"]=true,["weapon_rifle_springfield"]=true,["weapon_rifle_varmint"]=true,["weapon_shotgun_doublebarrel"]=true,["weapon_shotgun_pump"]=true,["weapon_shotgun_repeating"]=true,["weapon_shotgun_sawedoff"]=true,["weapon_shotgun_semiauto"]=true,["weapon_sniperrifle_carcano"]=true,["weapon_sniperrifle_rollingblock"]=true}
 for _,name in ipairs(names) do assert(expected[name]);expected[name]=nil end
 assert(next(expected)==nil and not sql:find('inventory_items',1,true) and not sql:find('row_revision',1,true))
 return 5
end}
dofile(root..'/server/services/native_weapon_item_policy.lua')
assert(InventoryNativeWeaponItemPolicy.Start() and InventoryNativeWeaponItemPolicy.Start() and calls==1)
Config.CharacterAmmunitionEnabled=false
dofile(root..'/server/services/native_weapon_item_policy.lua')
assert(InventoryNativeWeaponItemPolicy.Start() and calls==1)
Config.CharacterAmmunitionEnabled=true;DB.exec=function() return false end
assert(not pcall(InventoryNativeWeaponItemPolicy.Start),'failed startup write must not report readiness')
print('PASS melee definition usable reconciliation: exact 30, no instance writes, idempotence, disabled mode and failure refusal')
