-- Definition-only startup reconciliation. Never touches weapon instances or revisions.
InventoryNativeWeaponItemPolicy={}
local ready=false
local names={
    'weapon_melee_cleaver',
    'weapon_melee_hammer',
    'weapon_melee_hatchet',
    'weapon_melee_knife',
    'weapon_melee_machete',
    'weapon_pistol_m1899',
    'weapon_pistol_mauser',
    'weapon_pistol_semiauto',
    'weapon_pistol_volcanic',
    'weapon_repeater_carbine',
    'weapon_repeater_evans',
    'weapon_repeater_henry',
    'weapon_repeater_lancaster',
    'weapon_revolver_cattleman',
    'weapon_revolver_doubleaction',
    'weapon_revolver_lemat',
    'weapon_revolver_navy',
    'weapon_revolver_schofield',
    'weapon_rifle_boltaction',
    'weapon_rifle_elephant',
    'weapon_rifle_springfield',
    'weapon_rifle_varmint',
    'weapon_shotgun_doublebarrel',
    'weapon_shotgun_pump',
    'weapon_shotgun_repeating',
    'weapon_shotgun_sawedoff',
    'weapon_shotgun_semiauto',
    'weapon_sniperrifle_carcano',
    'weapon_sniperrifle_rollingblock',
    'weapon_thrown_tomahawk',
}
function InventoryNativeWeaponItemPolicy.Start()
    if ready or Config.CharacterAmmunitionEnabled~=true then return true end
    local marks={};for _=1,#names do marks[#marks+1]='?' end
    assert(DB.exec([[UPDATE items SET usable=0,
        description=CASE WHEN name='weapon_thrown_tomahawk' AND description='A standard throwing-tomahawk carrier.'
          THEN 'A standard throwing tomahawk.' ELSE description END
        WHERE name IN (]]..table.concat(marks,',')..[[)
        AND type='item_weapon' AND instance_mode='unique' AND (usable<>0
          OR (name='weapon_thrown_tomahawk' AND description='A standard throwing-tomahawk carrier.'))]],table.unpack(names))~=false,
        'Native weapon definition policy could not be applied')
    ready=true
    return true
end
