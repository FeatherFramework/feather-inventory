import assert from 'node:assert/strict';
import { createAmmoPanelLifetime } from '../src/ammoPanelLifetime.js';
const panel = createAmmoPanelLifetime();
const first = panel.invalidate();
assert.equal(panel.current(first), true);
panel.invalidate(); // Inventory close while options or transfer reply is pending
assert.equal(panel.current(first), false);
const second = panel.invalidate();
assert.equal(panel.current(first), false);
assert.equal(panel.current(second), true);
assert.equal(panel.capture(), second);
panel.invalidate(); // Escape / close / lifecycle-driven UI shutdown
assert.equal(panel.current(second), false);
const third = panel.invalidate();
panel.invalidate(); // Weapons resource stop invalidates pending presentation
assert.equal(panel.current(third), false);
const fourth = panel.invalidate();
panel.invalidate(); // new authoritative ledger presentation
assert.equal(panel.current(fourth), false);
console.log('Ammo panel lifetime PASS (late options/transfer replies cannot reopen or overwrite newer panels)');
