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

  ui_take_all: 'Take All',
  ui_condition: 'Condition',
  ui_condition_pristine: 'Pristine',
  ui_condition_worn: 'Worn',
  ui_condition_damaged: 'Damaged',
  ui_condition_ruined: 'Ruined',

  ui_paired_hint: 'Drag an entry between books to move it • Shift-click to send it across • ESC closes both',
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
// (§10.3) Wear stages come from Lua (thresholds from Config, labels
// localized), so the thresholds live in exactly one place. Empty until a
// payload arrives -- conditionStage() then simply finds no match and the UI
// shows the raw value, which is the right degradation.
const conditionStages = reactive({ list: [], max: 100 });

export function setConditionStages(stages, max) {
  conditionStages.list = Array.isArray(stages) ? [...stages] : [];
  conditionStages.max = Number(max) || 100;
}

// Highest matching threshold wins; stages arrive highest-first but this
// doesn't rely on that ordering.
export function conditionStage(value) {
  const n = Number(value);
  if (!Number.isFinite(n)) return null;
  let best = null;
  for (const stage of conditionStages.list) {
    if (n >= Number(stage.at) && (best === null || Number(stage.at) > Number(best.at))) {
      best = stage;
    }
  }
  return best ? best.label : null;
}

export function conditionMax() {
  return conditionStages.max;
}

export function t(key, ...args) {
  let out = strings[key] ?? DEFAULTS[key] ?? key;
  for (const arg of args) {
    out = out.replace('{n}', String(arg));
  }
  return out;
}
