<template>
  <div id="content" class="relative bg-gray-900 left-0 right-0 mx-auto px-10" v-if="visible || devmode">
    <div class="absolute right-2 top-0 text-2xl text-white" @click="closeApp">&times;</div>
    <MenuUI :player-inventory="playerInventory" :other-iventory="otherInventory" :global-options="globalOptions"></MenuUI>
  </div>
</template>

<script setup>
import api from "./api";
import { ref, onMounted, onUnmounted, reactive } from "vue";
import "@/assets/styles/main.scss";
import _ from "lodash"

import MenuUI from "./views/MenuUI.vue";

const devmode = ref(false);
const visible = ref(false);
const playerInventory = reactive({
  displayName: '',
  id: null,
  items: []
});
const otherInventory = reactive({
  displayName: '',
  id: null,
  items: []
});

const globalOptions = reactive({
  maxWeight: 0,
  maxItemSlots: 0,
  categories: []
});


onMounted(() => {
  window.addEventListener("message", onMessage);
});

onUnmounted(() => {
  window.removeEventListener("message", onMessage);
});

const onMessage = (event) => {
  switch (event.data.type) {
    case "toggleInventory":
      visible.value = event.data.visible;

      globalOptions.maxWeight = event.data.maxWeight;
      globalOptions.maxItemSlots = event.data.maxSlots;
      globalOptions.categories = event.data.categories;

      playerInventory.items = {}
      otherInventory.items = {}

      // Set data
      if (typeof event.data.playerItems !== "undefined" && event.data.playerItems !== null) {
        playerInventory.name = "Inventory"
        playerInventory.id = event.data.playerInventory
        let tempPlayerItems = _.map(event.data.playerItems, (item) => {
          return {
            id: item.id,
            name: item.name,
            displayName: item.display_name,
            description: item.description,
            usable: item.usable,
            weight: item.weight,
            category: item.category_id,
            maxQuantity: item.max_quantity,
            maxStackSize: item.max_stack_size
          }
        });



        let groupedPlayerItems = _.groupBy(tempPlayerItems, (item) => item.name)
        let outputPlayerItems = []

        playerInventory.items = _.forEach(groupedPlayerItems, (itemGroup, key) => {
          let chunked = _.chunk(itemGroup, itemGroup[0].maxStackSize)


          outputPlayerItems.push({
            key: key,
            items: chunked
          })
        });

        playerInventory.items = outputPlayerItems
      }

      if (typeof event.data.otherItems !== "undefined" && event.data.otherItems !== null) {
        otherInventory.name = "Other"
        otherInventory.id = event.data.otherInventory
        otherInventory.items = _.map(event.data.otherItems, (item) => {
          return {
            id: item.id,
            name: item.name,
            displayName: item.display_name,
            description: item.description,
            usable: item.usable,
            weight: item.weight,
            category: item.category_id,
            maxQuantity: item.max_quantity,
            maxStackSize: item.max_stack_size
          }
        });
      }
      break;
    default:
      break;
  }
};

const closeApp = () => {
  visible.value = false;
  api
    .post("Feather:Inventory:CloseInventory", {
      state: visible.value,
    })
    .catch((e) => {
      console.log(e.message);
    });
};
</script>

<style>
#content {
  width: 60vw;
  height: 70vh;
}
</style>
