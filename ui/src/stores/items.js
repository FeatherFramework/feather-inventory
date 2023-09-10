import { defineStore } from "pinia";

export const useItemsStore = defineStore("items", {
  state: () => ({
    playerItems: [],
    otherItems: [],
    metadata: {},
  }),
  getters: {
    // Return all metadata for given item id.
    getMetadata(state) {
      return (itemId) => state.metadata[itemId];
    },
  },
  actions: {
    store(key, value) {
      this[key] = value;
    },
    addItem(key, value) {
      this[key].push(value);
    },
    addMetadata(id, key, value) {
      if (typeof this.metadata[id] === "undefined" || this.metadata[id] === null) {
        this.metadata[id] = {};
      }
      this.metadata[id][key] = value;
    },
  },
});
