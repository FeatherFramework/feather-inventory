import { defineStore } from "pinia";

export const useItemsStore = defineStore("items", {
  state: () => ({
    playerItems: null,
    otherItems: null,
  }),
  getters: {
    getPlayerItems(state) {
      return state.playerItems;
    },
    getOtherItems(state) {
      return state.otherItems;
    },
  },
  actions: {
    storePlayerItems(playerItems) {
      this.playerItems = playerItems;
    },
    storeOtherItems(otherItems) {
      this.otherItems = otherItems;
    },
  },
});
