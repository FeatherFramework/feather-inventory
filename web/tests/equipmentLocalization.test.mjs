import assert from 'node:assert/strict';
import fs from 'node:fs';
import { equipmentDefaults, equipmentSlotLabel, equipmentOptionLabel } from '../src/equipmentPresentation.js';
import * as john from '../src/i18n.js?john';
import * as jane from '../src/i18n.js?jane';

john.setStrings({ ui_equipment_utility_number: 'Utilitaire {n}', ui_equipment_equip: 'Equiper' });
jane.setStrings({ ui_equipment_utility_number: 'Equipo {n}', ui_equipment_equip: 'Equipar' });
const option = { action: 'equip', slot: 'weapon_utility_quinary', label: 'Equip — Utility 5' };
assert.equal(equipmentOptionLabel(option, john.t), 'Equiper — Utilitaire 5');
assert.equal(equipmentOptionLabel(option, jane.t), 'Equipar — Equipo 5');
assert.equal(john.t('ui_equipment_help'), equipmentDefaults.ui_equipment_help, 'missing key falls back to English');
assert.equal(equipmentSlotLabel({ slot: 'weapon_utility_quaternary' }, jane.t), 'Equipo 4');
assert.equal(equipmentSlotLabel({ slot: 'weapon_utility_senary' }, jane.t), 'Equipo 6');
assert.equal(equipmentSlotLabel({ slot: 'weapon_utility_septenary' }, jane.t), 'Equipo 7');
assert.equal(equipmentSlotLabel({ slot: 'weapon_utility_octonary' }, jane.t), 'Equipo 8');
assert.equal(equipmentOptionLabel({action:'equip',slot:'weapon_utility_octonary'}, john.t), 'Equiper — Utilitaire 8');
assert.equal(equipmentOptionLabel({action:'equip',slot:'weapon_utility_senary'}, john.t), 'Equiper — Utilitaire 6');
const before = JSON.stringify(option);
john.setStrings({ ui_equipment_utility_number: 'New {n}', ui_equipment_equip: 'New equip' });
assert.equal(equipmentOptionLabel(option, john.t), 'New equip — New 5');
assert.equal(JSON.stringify(option), before, 'locale updates never mutate the authoritative intent');
assert.equal(equipmentOptionLabel(option, jane.t), 'Equipar — Equipo 5', 'other client bundle remains independent');
john.setStrings({ ui_equipment_attachment_sight: 'Localized sight' });
john.setStrings({});
assert.equal(john.t('ui_equipment_attachment_sight'), 'ui_equipment_attachment_sight', 'old-language extra keys cannot leak');
assert.equal(equipmentOptionLabel(option, john.t), 'Equip — Utility 5');
for (const key of Object.keys(equipmentDefaults)) {
  const controller = fs.readFileSync(new URL('../../client/controllers/inventory.lua', import.meta.url), 'utf8');
  const english = fs.readFileSync(new URL('../../translations/en_us.lua', import.meta.url), 'utf8');
  assert.ok(controller.includes("'" + key + "'"), 'Lua bundle includes ' + key);
  assert.ok(english.includes(key + ' ='), 'English dictionary includes ' + key);
}
const app = fs.readFileSync(new URL('../src/App.vue', import.meta.url), 'utf8');
const handler = app.match(/if \(data.type === 'localeStrings'\) \{([\s\S]*?)\n  \}/)[1];
assert.ok(handler.includes('setStrings(data.strings)'));
assert.ok(!handler.includes('closeAmmoPanel') && !handler.includes('equipmentScope'), 'text refresh preserves in-flight scope');
console.log('Equipment localization PASS: separate recipients, live text update, English fallback and unchanged intents');
