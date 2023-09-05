import { defineStore } from "pinia";

export const useSessionStore = defineStore("session", {
  state: () => ({
    inventoryId: null,
    otherInventoryId: null,
    maxWeight: null,
    maxItemSlots: null,
  }),
  getters: {},
  actions: {
    storeInventoryId(inventoryId) {
      this.inventoryId = inventoryId;
    },
    storeOtherInventoryId(otherInventoryId) {
      this.otherInventoryId = otherInventoryId;
    },
    storeMaxWeight(maxWeight) {
      this.maxWeight = maxWeight;
    },
    storeMaxItemSlots(maxItemSlots) {
      this.maxItemSlots = maxItemSlots;
    },
  },
});
