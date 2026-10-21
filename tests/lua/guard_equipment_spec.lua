-- Real guard/equipment APIs with a deterministic locked-query model.
local root = arg and arg[1] or '.'
warn = function() end
CreateThread = function() end
local fallbackReads, lockedReads = 0, 0
DB = { query = function() fallbackReads = fallbackReads + 1; return {} end }
Result = { Ok = function(value) return { ok = true, value = value } end,
  Err = function() return { ok = false } end, Codes = {} }
dofile(root .. '/server/services/guards.lua')
dofile(root .. '/server/services/equipment.lua')
local function query(sql, ids)
  assert(sql:find('FOR UPDATE', 1, true))
  assert(#ids <= 200)
  lockedReads = lockedReads + 1
  local result = {}
  for _, id in ipairs(ids) do
    if id == 2 then result[#result + 1] = { inventory_items_id = id } end
  end
  return result
end
local rows = {}
for id = 1, 30 do rows[id] = { id = id } end
assert(GuardsAPI.PrepareMoveSnapshots(query, rows) and lockedReads == 0)
GuardsAPI.RegisterMoveGuard('weapons', function(instance)
  local equipped = EquipmentAPI.IsInstanceEquipped(instance.id)
  if equipped.value then return false, 'Unequip first' end
  return instance.id ~= 3, 'Administrative hold'
end)
assert(GuardsAPI.PrepareMoveSnapshots(query, rows))
assert(lockedReads == 1)
for _, row in ipairs(rows) do
  local allowed = GuardsAPI.CanMoveInstanceSnapshot({ id = row.id,
    equipmentSnapshot = { equipped = row._equipmentEquipped } })
  assert(allowed == (row.id ~= 2 and row.id ~= 3))
  local _, verified = GuardsAPI.GetLockedEquipmentState(row.id)
  assert(not verified, 'Snapshot leaked beyond guard evaluation')
end
assert(fallbackReads == 0, 'Per-item equipment reads were not eliminated')
EquipmentAPI.IsInstanceEquipped(1)
assert(fallbackReads == 1, 'Ordinary equipment reads must retain DB path')
for id = 31, 201 do rows[id] = { id = id } end
assert(GuardsAPI.PrepareMoveSnapshots(query, rows) and lockedReads == 3)
assert(not GuardsAPI.PrepareMoveSnapshots(function() return nil end, rows))
GuardsAPI.RegisterMoveGuard('weapons', function() error('consumer failed') end)
assert(not GuardsAPI.CanMoveInstanceSnapshot({ id = 1, equipmentSnapshot = { equipped = false } }))
local _, verified = GuardsAPI.GetLockedEquipmentState(1)
assert(not verified, 'Error leaked snapshot')
GuardsAPI.RegisterMoveGuard('weapons', function(instance, context)
  assert(EquipmentAPI.IsInstanceEquipped(instance.id).value == false)
  if not context.nested then
    assert(GuardsAPI.CanMoveInstanceSnapshot(instance, { nested = true }))
    assert(EquipmentAPI.IsInstanceEquipped(instance.id).value == false)
  end
  return true
end)
assert(GuardsAPI.CanMoveInstanceSnapshot({ id = 1, equipmentSnapshot = { equipped = false } }, {}))
assert(fallbackReads == 1)
GuardsAPI.RegisterDestroyGuard('weapons', function(instance)
  return not EquipmentAPI.IsInstanceEquipped(instance.id).value
end)
assert(GuardsAPI.HasRegisteredGuard('weapons'))
assert(not GuardsAPI.HasRegisteredGuard('unregistered-consumer'))
assert(GuardsAPI.PrepareDestroySnapshots(query, rows))
assert(not GuardsAPI.CanDestroyInstanceSnapshot({ id = 2, equipmentSnapshot = { equipped = true } }))
assert(GuardsAPI.CanDestroyInstanceSnapshot({ id = 1, equipmentSnapshot = { equipped = false } }))
assert(fallbackReads == 1, 'Destruction guard must reuse locked equipment state')
local _, destructionVerified = GuardsAPI.GetLockedEquipmentState(2)
assert(not destructionVerified)
-- A consumer with a missing/malformed return has not granted permission.
for _,kind in ipairs({'Move','Destroy','InstanceChange'}) do
  local register=GuardsAPI['Register'..kind..'Guard']
  local evaluate=kind=='InstanceChange' and function()
    return GuardsAPI.CanChangeInstance(1,{})
  end or function()
    return GuardsAPI['Can'..(kind=='Move' and 'Move' or 'Destroy')..'InstanceSnapshot'](
      {id=1,equipmentSnapshot={equipped=false}},{})
  end
  for _,callback in ipairs({function() end,function() return 1 end,
    function() return 'true' end,function() return {ok=true} end}) do
    register('malformed',callback)
    assert(not evaluate(),'non-boolean guard result must fail closed: '..kind)
  end
  register('malformed',function() return true end)
  assert(evaluate(),'explicit true remains accepted: '..kind)
end
-- Compose the actual Weapons native guard with Inventory's locked snapshot
-- runner. This is a cross-repo mock boundary test, not live storage acceptance.
GuardsAPI.UnregisterMoveGuard('weapons')
GuardsAPI.UnregisterDestroyGuard('weapons')
Config={CharacterAmmunitionEnabled=true,CharacterAmmoTransportEnabled=true,Inventory={requiredContract=4}}
local nativeAdapter=io.open(root .. '/../feather-weapons/server/adapters/character_ammunition_inventory.lua','r')
if nativeAdapter then
nativeAdapter:close()
dofile(root .. '/../feather-weapons/server/adapters/character_ammunition_inventory.lua')
local nativeHeld,adminHeld=true,false
local provider=WeaponCharacterAmmoInventory.New(function()
 return {GetCapabilities=function() return Result.Ok({contractVersion=4,characterIdentity={uuid=true,mode='uuid'}}) end,
 Guards=GuardsAPI,Equipment=EquipmentAPI}
end,function() return nativeHeld end,function() return not adminHeld,'Administrative hold' end)
assert(provider.Install())
local metadata={serialNumber='PRESERVED',attachments={{definitionId='carbine_wide_sight',slot='sight'}},
 maintenance={dirt=0.2},provenance={owner='Jane'}}
local item={id=135,metadata=metadata,equipmentSnapshot={equipped=false}}
local beforeFallback=fallbackReads
assert(not GuardsAPI.CanMoveInstanceSnapshot(item,{}),'native-owned item cannot leave inventory')
assert(not GuardsAPI.CanDestroyInstanceSnapshot(item,{}),'native-owned item cannot be destroyed')
assert(not GuardsAPI.CanChangeInstance(135,{}),'native-owned metadata remains held')
nativeHeld=false; item.equipmentSnapshot.equipped=true
assert(not GuardsAPI.CanMoveInstanceSnapshot(item,{}),'saved equipped assignment independently vetoes move')
item.equipmentSnapshot.equipped=false; adminHeld=true
assert(not GuardsAPI.CanMoveInstanceSnapshot(item,{}),'administrative hold survives native release')
adminHeld=false
assert(GuardsAPI.CanMoveInstanceSnapshot(item,{}) and GuardsAPI.CanDestroyInstanceSnapshot(item,{}))
assert(fallbackReads==beforeFallback,'native guard must use locked equipment snapshot, not query another connection')
assert(item.metadata==metadata and metadata.serialNumber=='PRESERVED'
 and metadata.attachments[1].definitionId=='carbine_wide_sight' and metadata.maintenance.dirt==0.2
 and metadata.provenance.owner=='Jane','guard evaluation cannot mutate instance identity/customization')
else print('SKIP optional sibling Weapons native guard composition (repository not present)') end
print('PASS equipment guard snapshots: movement/destruction vetoes, bulk reads, fallback, cleanup, nested guards')
Config={CharacterAmmunitionEnabled=true}
GetConvarInt=function() return 1 end
assert(not EquipmentAPI.SetEquippedForCharacter('john','weapon_melee',90).ok,
 'generic equipment API cannot bypass native knife conditional coordinator')
assert(not EquipmentAPI.SetEquippedForCharacter('john','weapon_throwable',170).ok,
 'generic equipment API cannot bypass native throwable conditional coordinator')
for _,slot in ipairs({'weapon_melee_secondary','weapon_melee_tertiary','weapon_melee_quaternary','weapon_melee_quinary'}) do
 assert(not EquipmentAPI.SetEquippedForCharacter('john',slot,90).ok,
  'generic equipment API cannot bypass aggregate native melee coordinator')
end
