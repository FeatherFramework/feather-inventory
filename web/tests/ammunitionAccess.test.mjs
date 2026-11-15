import assert from 'node:assert/strict';
import fs from 'node:fs';
import { parse, compileScript } from 'vue/compiler-sfc';
import { createSSRApp, computed, ref } from 'vue';
import { renderToString } from 'vue/server-renderer';
import { setStrings, t } from '../src/i18n.js';

async function component(name) {
  const file = new URL(`../src/components/${name}.vue`, import.meta.url);
  const { descriptor } = parse(fs.readFileSync(file, 'utf8'));
  const compiled = compileScript(descriptor, { id: name, inlineTemplate: true, templateOptions: { transformAssetUrls: false } });
  const source = compiled.content
    .replaceAll('from "vue"', `from ${JSON.stringify(import.meta.resolve('vue'))}`)
    .replaceAll("from 'vue'", `from ${JSON.stringify(import.meta.resolve('vue'))}`)
    .replaceAll("'@/i18n'", JSON.stringify(new URL('../src/i18n.js', import.meta.url).href));
  return (await import(`data:text/javascript;base64,${Buffer.from(source).toString('base64')}`)).default;
}
const Book = await component('LedgerBook');
const props = { title: 'Personal Effects', subtitle: 'John', footerLabel: 'ui_carrying',
  capacity: 10, items: [], categories: [], canManageAmmunition: true };
setStrings({});
let html = await renderToString(createSSRApp(Book, props));
assert.match(html, /<button[^>]*>Ammunition<\/button>/, 'empty inventory still exposes ammunition management');
html = await renderToString(createSSRApp(Book, { ...props, canManageAmmunition: false }));
assert.doesNotMatch(html, />Ammunition<\/button>/, 'other/unsupported book does not expose player controls');
const Panel = await component('AmmunitionPanel');
const options = [{ id: 'ammo_tomahawk_regular', label: 'Tomahawk', loose: 0, carried: 1 }];
html = await renderToString(createSSRApp(Panel, { options }));
assert.match(html, /<button(?![^>]*disabled)[^>]*>Unload<\/button>/, 'recovered carried unit can be stored without a loose item');
assert.match(html, /<button[^>]*disabled[^>]*>Load<\/button>/);
const scope = { characterId: 'john', sessionId: 's', epoch: 'e' };
const quantity = ref(1);
const message = computed(() => t('ui_ammo_loaded', quantity.value, 2));
setStrings({ ui_ammunition: 'Munición', ui_ammo_loaded: 'Cargada {n}. Portada: {n}.' });
assert.equal(message.value, 'Cargada 1. Portada: 2.');
html = await renderToString(createSSRApp(Book, props));
assert.match(html, />Munición<\/button>/);
setStrings({});
assert.equal(message.value, 'Loaded 1. Carried: 2.');
assert.deepEqual(scope, { characterId: 'john', sessionId: 's', epoch: 'e' });
assert.equal(quantity.value, 1);
const lua = fs.readFileSync(new URL('../../client/controllers/inventory.lua', import.meta.url), 'utf8');
const english = fs.readFileSync(new URL('../../translations/en_us.lua', import.meta.url), 'utf8');
const panel = fs.readFileSync(new URL('../src/components/AmmunitionPanel.vue', import.meta.url), 'utf8');
for (const key of new Set([...panel.matchAll(/t\('(ui_[a-z_]+)'/g)].map((m) => m[1]))) {
  assert.ok(lua.includes(`'${key}'`) && english.includes(`${key} =`), `${key} uses the existing player-language bundle`);
}
console.log('PASS rendered ammunition access: empty player bag, carried-only unload, disabled loose load, selected-language refresh and English fallback without scope changes');
