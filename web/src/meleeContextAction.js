export const isNativeFirearm = (item) => /^weapon_(revolver|pistol|repeater|rifle|sniperrifle|shotgun)_/.test(item?.name || '');
export const isNativeMelee = (item) => /^weapon_melee_(knife|machete|hammer|cleaver|hatchet)$/.test(item?.name || '');
export const isNativeThrowable = (item) => item?.name === 'weapon_thrown_tomahawk';

export function carriedThrowableUnits(value) {
  if (!Array.isArray(value) || value.length > 3) return [];
  const ids = new Set();
  for (const row of value) {
    if (!Number.isSafeInteger(row?.id) || row.id < 1 || ids.has(row.id)) return [];
    ids.add(row.id);
  }
  return value.map(({id}) => ({id})).sort((a, b) => a.id - b.id);
}

// Options are server-authorized. Never infer equipped state from an icon or cache.
export async function loadMeleeContextAction(menu, itemId, post, current, throwable = false) {
  menu.equipmentLoading = true;
  menu.equipmentAction = null;
  try {
    const { data } = await post('Feather:Inventory:NativeEquipmentOptions', { itemId });
    if (!current()) return;
    const options = data?.ok && Array.isArray(data.value?.options) ? data.value.options : [];
    const option = options.length === 1 ? options[0] : null;
    if (option && !option.kind && ['equip', 'unequip'].includes(option.action)
        && (throwable ? option.slot === 'weapon_throwable' : /^weapon_melee(?:_(secondary|tertiary|quaternary|quinary))?$/.test(option.slot))
        && data.value.identity) {
      menu.equipmentAction = { option, scope: data.value.identity, itemId };
    }
  } catch { /* Failed readback leaves a disabled action; no automatic replay. */ }
  finally { if (current()) menu.equipmentLoading = false; }
}
