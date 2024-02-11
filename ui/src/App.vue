<template>
  <div id="content" class="flex flex-col h-screen justify-center items-center" style="width: 100vw; height: 100vh;" v-if="visible || devmode">
    <div class="bg-zinc-900 px-4 relative mx-auto pt-10 bg-opacity-90" :style="`${ globalOptions.target != 'player' ? 'width: 80vw;' : ''} height: 80vh;`">
      <div class="absolute right-2 top-0 text-2xl text-white hover:text-red-500" @click="closeApp">&times;</div>
      <MenuUI :player-inventory="playerInventory" :other-iventory="otherInventory" :global-options="globalOptions" :target="globalOptions.target">
      </MenuUI>
    </div>
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
  categories: [],
  target: ''
});

// TODO: Add Inventory specific slot counts
// TODO: Account for inventory specific ignore limits (ignore item caps)


onMounted(() => {
  window.addEventListener("message", onMessage);
});

onUnmounted(() => {
  window.removeEventListener("message", onMessage);
});

const translateItems = (items) => {
  let tempItems = _.map(items, (item) => {
    return {
      id: item.id,
      name: item.name,
      displayName: item.display_name,
      description: item.description,
      usable: item.usable,
      weight: item.weight,
      category: item.category_id,
      maxQuantity: item.max_quantity,
      maxStackSize: item.max_stack_size,
      metadata: item.item_metadata
    }
  });

  let groupedItems = _.groupBy(tempItems, (item) => item.name)
  let outputItems = []

  _.forEach(groupedItems, (itemGroup, key) => {
    let sorted = _.sortBy(itemGroup, (item) => {
      return item.metadata !== null
    })
    
    let chunked = _.chunk(sorted, itemGroup[0].maxStackSize)
    outputItems = outputItems.concat(chunked)
  });

  return outputItems
}

const onMessage = (event) => {
  switch (event.data.type) {
    case "toggleInventory":
      visible.value = event.data.visible;

      globalOptions.maxWeight = event.data.maxWeight;
      globalOptions.maxItemSlots = event.data.maxSlots;
      globalOptions.categories = event.data.categories;
      globalOptions.target = event.data.target

      playerInventory.items = {}
      otherInventory.items = {}

      console.log(event.data)

      // Set data
      if (typeof event.data.playerItems !== "undefined" && event.data.playerItems !== null) {
        playerInventory.name = "Inventory"
        playerInventory.id = event.data.playerInventory
        playerInventory.items = translateItems(event.data.playerItems)
      }

      if (typeof event.data.otherItems !== "undefined" && event.data.otherItems !== null) {
        otherInventory.name = "Other"
        otherInventory.id = event.data.otherInventory
        otherInventory.items = translateItems(event.data.otherItems)
      }
      break;
    default:
      break;
  }
};

const closeApp = () => {
  visible.value = false;
  api
    .post("Feather:Inventory:NuiCloseInventory", {
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
