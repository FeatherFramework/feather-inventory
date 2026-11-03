// English fallback only; Lua supplies the current player's translated bundle.
export const equipmentDefaults = {
  "ui_equipment_title": "Equipment",
  "ui_equipment_help": "Choose where to carry this weapon. Ammunition stays in your shared carried pools.",
  "ui_equipment_slots": "Equipment slot occupancy",
  "ui_equipment_selected": "This item",
  "ui_equipment_occupied": "Occupied",
  "ui_equipment_open": "Open",
  "ui_equipment_item": "Item #{n}",
  "ui_equipment_hint": "Open means empty, not necessarily compatible. Only permitted actions appear below. Only one lasso can be equipped.",
  "ui_equipment_attachment_hint": "Installing an attachment uses one matching item. Removal returns it to your inventory.",
  "ui_equipment_repair_hint": "Cleaning uses the listed material. Permanent wear cannot be repaired away.",
  "ui_equipment_equip": "Equip",
  "ui_equipment_unequip": "Unequip",
  "ui_equipment_install": "Install",
  "ui_equipment_remove": "Remove",
  "ui_equipment_repair": "Clean / repair",
  "ui_equipment_close": "Close",
  "ui_equipment_primary": "Primary",
  "ui_equipment_offhand": "Offhand",
  "ui_equipment_shoulder": "Shoulder",
  "ui_equipment_back": "Back",
  "ui_equipment_melee": "Melee",
  "ui_equipment_melee_number": "Melee {n}",
  "ui_equipment_throwable": "Throwable",
  "ui_equipment_utility": "Utility",
  "ui_equipment_utility_number": "Utility {n}",
  "ui_equipment_checking": "Checking equipment…",
  "ui_equipment_none": "No supported equipment action for this weapon.",
  "ui_equipment_unavailable": "Equipment controls unavailable.",
  "ui_equipment_updated": "Equipment updated. Reopen Equipment for another action.",
  "ui_equipment_uncertain": "Equipment result uncertain. Do not retry; check Weapons status."
};

const slots = {
  weapon: ['primary'], weapon_offhand: ['offhand'], weapon_shoulder: ['shoulder'], weapon_back: ['back'],
  weapon_melee: ['melee'], weapon_melee_secondary: ['melee_number', 2],
  weapon_melee_tertiary: ['melee_number', 3], weapon_melee_quaternary: ['melee_number', 4],
  weapon_melee_quinary: ['melee_number', 5], weapon_throwable: ['throwable'],
  weapon_utility: ['utility'], weapon_utility_secondary: ['utility_number', 2],
  weapon_utility_tertiary: ['utility_number', 3], weapon_utility_quaternary: ['utility_number', 4],
  weapon_utility_quinary: ['utility_number', 5],
  weapon_utility_senary: ['utility_number', 6],
  weapon_utility_octonary: ['utility_number', 8],
  weapon_utility_septenary: ['utility_number', 7],
};
export function equipmentSlotLabel(slot, t) {
  const entry = slots[slot.slot];
  return entry ? t('ui_equipment_' + entry[0], ...(entry.length > 1 ? [entry[1]] : [])) : slot.label;
}
export function equipmentOptionLabel(option, t) {
  if (!option.kind && ['equip', 'unequip'].includes(option.action) && slots[option.slot]) {
    return t('ui_equipment_' + option.action) + ' — ' + equipmentSlotLabel(option, t);
  }
  if (option.kind === 'repair') return t('ui_equipment_repair') + (option.label?.includes(' — ') ? ' — ' + option.label.split(' — ').slice(1).join(' — ') : '');
  if (option.kind === 'attachment' && ['install', 'remove'].includes(option.action)) {
    // Canonical attachment name falls back to the server's English definition.
    const key = 'ui_equipment_attachment_' + option.attachmentId;
    const name = t(key);
    return t('ui_equipment_' + option.action) + ' — ' + (name === key ? option.label?.split(' — ').slice(1).join(' — ') || option.attachmentId : name);
  }
  return option.label;
}
