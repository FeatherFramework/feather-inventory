import { defineStore } from "pinia";

export const useSessionStore = defineStore("session", {
  state: () => ({
    inventoryId: null,
    otherInventoryId: null,
    maxWeight: null,
    maxItemSlots: null,
    categories: null,
  }),
  getters: {},
  actions: {
    store(key, value) {
      this[key] = value;
    },
  },
});
