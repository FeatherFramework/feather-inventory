<template>
  <div id="content" class="flex flex-col h-screen justify-center items-center" style="width: 100vw; height: 100vh;"
    v-if="visible || devmode">
    <div class="bg-zinc-900 px-4 relative mx-auto pt-10 bg-opacity-70 rounded-md"
      :style="`${globalOptions.target != 'player' ? 'width: 80vw;' : ''} height: 80vh;`">
      <div class="absolute right-2 top-0 text-2xl text-white hover:text-red-500" @click="closeApp">&times;</div>
      <MenuUI :player-inventory="playerInventory" :other-iventory="otherInventory" :global-options="globalOptions"
        :target="globalOptions.target" :player-display="playerDisplay" @transfer="transferItems">
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

// TODO: At a later date, MAYBE move this all to state management :/
// TODO: Add Inventory specific slot counts
// TODO: Account for inventory specific ignore limits (ignore item caps)

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

const playerDisplay = reactive({
  dollars: '',
  gold: '',
  tokens: '',
  id: 0
})



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
      metadata: item.item_metadata,
      updatedAt: item.updated_at
    }
  });

  let groupedItems = _.groupBy(tempItems, (item) => item.name)
  let outputItems = []

  _.forEach(groupedItems, (itemGroup, key) => {
    let sorted = _.sortBy(itemGroup, ['updatedAt'])

    let chunked = _.chunk(sorted, itemGroup[0].maxStackSize)
    outputItems = outputItems.concat(chunked)
  });

  return outputItems
}

const onMessage = (event) => {
  switch (event.data.type) {
    case "toggleInventory":
      let data = event.data;

      visible.value = data.visible;

      playerDisplay.id = data.player.id;
      playerDisplay.gold = data.player.gold;
      playerDisplay.dollars = data.player.dollars;
      playerDisplay.tokens = data.player.tokens;

      globalOptions.maxWeight = data.maxWeight;
      globalOptions.maxItemSlots = data.maxSlots;
      globalOptions.categories = data.categories;
      globalOptions.target = data.target;

      if (typeof data.playerItems !== "undefined" && data.playerItems !== null) {
        playerInventory.name = "Inventory"
        playerInventory.id = data.playerInventory
        hydrateInventoryItems('player', data);
      }

      if (typeof data.otherItems !== "undefined" && data.otherItems !== null) {
        otherInventory.name = "Other"
        otherInventory.id = data.otherInventory
        hydrateInventoryItems('other', data);
      }
      break;
    default:
      break;
  }
};

const hydrateInventoryItems = (location, data) => {
  if (location == 'player') {
    playerInventory.items = {}
    playerInventory.items = translateItems(data.playerItems)
  } else if (location == 'other') {
    otherInventory.items = {}
    otherInventory.items = translateItems(data.otherItems)
  } else {
    playerInventory.items = {}
    playerInventory.items = translateItems(data.playerItems)

    otherInventory.items = {}
    otherInventory.items = translateItems(data.otherItems)
  }
}

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

const transferItems = (dropzoneid, items) => {
  //Disable the UI while transfering
  const shieldinv = document.querySelectorAll('.shieldinv');
  shieldinv.forEach(shield => shield.style.display = 'block')


  let targetid = null
  let sourceid = null

  if (dropzoneid == `dropzone-left`) {
    sourceid = otherInventory.id
    targetid = playerInventory.id
  } else {
    sourceid = playerInventory.id
    targetid = otherInventory.id
  }

  api.post("Feather:Inventory:UpdateInventory", {
    sourceInventory: sourceid,
    targetInventory: targetid,
    items: items
  })
    .then(({data}) => {
      var outputItems = {}
      if (dropzoneid == `dropzone-left`) {
        outputItems = {
          playerItems: data.targetItems,
          otherItems: data.sourceItems
        }
      } else {
        outputItems = {
          playerItems: data.sourceItems,
          otherItems: data.targetItems
        }
      }

      hydrateInventoryItems('both', outputItems);
      const shieldinv = document.querySelectorAll('.shieldinv');
      shieldinv.forEach(shield => shield.style.display = 'none')
    })
    .catch((e) => {
      const shieldinv = document.querySelectorAll('.shieldinv');
      shieldinv.forEach(shield => shield.style.display = 'none')
      console.log(e.message);
    });
}

</script>

<style>
@font-face {
  font-family: rdrlino;
  src: url(assets/fonts/rdrlino-regular.ttf);
}

@font-face {
  font-family: chinarocks;
  src: url(assets/fonts/chinese-rocks.ttf);
}

#content {
  width: 60vw;
  height: 70vh;
}

#app {
  font-family: rdrlino;
  touch-action: manipulation;
  -webkit-font-smoothing: antialiased;
  -moz-osx-font-smoothing: grayscale;
}

.rdrlino {
  font-family: rdrlino !important;
}

.chinarocks {
  font-family: chinarocks !important;
}

::-webkit-scrollbar {
  display: none;
}

.ghost {
  pointer-events: none;
  position: absolute;
  opacity: 0;
  z-index: 99999;
}
</style>
