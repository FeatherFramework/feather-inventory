import assert from 'node:assert/strict';
import { createAmmoPanelLifetime } from '../src/ammoPanelLifetime.js';

// Equipment uses this same generation guard for options and completion replies.
for (const boundary of ['logout', 'death', 'provider-stop', 'new-ledger', 'close']) {
  const lifetime = createAmmoPanelLifetime();
  const options = lifetime.capture();
  const completion = lifetime.capture();
  lifetime.invalidate();
  assert.equal(lifetime.current(options), false, `${boundary}: old options rejected`);
  assert.equal(lifetime.current(completion), false, `${boundary}: old completion rejected`);
  const reopened = lifetime.capture();
  assert.equal(lifetime.current(reopened), true);
  assert.equal(lifetime.current(completion), false, `${boundary}: no overwrite of reopened panel`);
}
console.log('Equipment generation guard PASS (late options/completion after lifecycle boundaries; helper only)');
