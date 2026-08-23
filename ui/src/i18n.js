import { reactive } from 'vue';

// (§10.2 locale migration) The ledger's labels come from Lua -- translations/
// is the single source of truth for every user-facing string in this
// resource, and the client resolves them in the player's language before
// handing the bundle to the NUI (see client/controllers/inventory.lua).
//
// These English defaults are the fallback layer, not a second locale system.
// They cover three real cases: a key missing from translations/, a server
// older than the `strings` payload field, and the Vite dev server, where
// there's no Lua side at all. Without them a missing key renders as an empty
// label, which is worse than untranslated English.
const DEFAULTS = {
  ui_personal_effects: 'PERSONAL EFFECTS',
  ui_storage: 'STORAGE',
  ui_carrying: 'CARRYING',
  ui_stored: 'STORED',
  ui_all: 'ALL',

  ui_use: 'Use',
  ui_give: 'Give',
  ui_drop: 'Drop',
  ui_split: 'Split',
  ui_cancel: 'Cancel',
  ui_confirm: 'Confirm',

  ui_quantity: 'Quantity',
  ui_weight: 'Weight',
  ui_how_many: 'How many? (1-{n})',
  ui_use_all: 'Use all ({n})',
  ui_invalid_amount: 'Invalid amount.',
  ui_no_entry: 'No entry selected.',

  ui_paired_hint: 'Drag an entry from one book to the other to move it • ESC closes both',
};

const strings = reactive({ ...DEFAULTS });

// Reset to defaults before applying, so reopening the inventory after a
// language change can't leave a stale string from the previous bundle.
export function setStrings(incoming) {
  Object.assign(strings, DEFAULTS);
  if (!incoming || typeof incoming !== 'object') return;

  for (const [key, value] of Object.entries(incoming)) {
    if (typeof value === 'string' && value.length > 0) {
      strings[key] = value;
    }
  }
}

// Substitutes {n} placeholders positionally.
//
// Deliberately {n} and not %s: Feather.Locale.translate runs every string
// through Lua's string.format before it reaches this bundle, and these
// templates are resolved with no arguments (only the UI knows the runtime
// value). A %s would therefore blow up format() on the Lua side before the
// string ever got here. {n} means nothing to string.format and survives the
// trip intact.
export function t(key, ...args) {
  let out = strings[key] ?? DEFAULTS[key] ?? key;
  for (const arg of args) {
    out = out.replace('{n}', String(arg));
  }
  return out;
}
