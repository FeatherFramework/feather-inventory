// A late reply may complete an operation, but must never resurrect a panel
// belonging to a closed Inventory or overwrite a newer panel's UI state.
export function createAmmoPanelLifetime() {
  let generation = 0;
  return {
    capture: () => generation,
    invalidate: () => ++generation,
    current: (ticket) => ticket === generation,
  };
}
