<template>
  <div id="content" class="relative bg-gray-900 left-0 right-0 mx-auto px-10" v-if="visible || devmode">
    <div class="absolute right-2 top-0 text-2xl text-white" @click="closeApp">&times;</div>
    <nav class="w-full text-center text-white"><router-link to="/">Home</router-link> |</nav>
    <router-view />
  </div>
</template>

<script setup>
  import api from "./api";
  import { ref, onMounted, onUnmounted } from "vue";
  import { useSessionStore } from "@/stores/session";
  import { useItemsStore } from "@/stores/items";
  import "@/assets/styles/main.scss";

  const devmode = ref(false);
  const visible = ref(false);

  const sessionStore = useSessionStore();
  const itemsStore = useItemsStore();

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

        sessionStore.store("maxWeight", event.data.maxWeight);
        sessionStore.store("maxItemSlots", event.data.maxSlots);
        sessionStore.store("inventoryId", event.data.playerInventory);
        sessionStore.store("otherInventoryId", event.data.otherInventory);
        sessionStore.store("categories", event.data.categories);

        // Clear data if its present
        itemsStore.store("playerItems", []);
        itemsStore.store("otherItems", []);
        itemsStore.store("metadata", {});

        // Set data
        let items = [];
        if (typeof event.data.playerItems !== "undefined" && event.data.playerItems !== null) {
          const playerItemsLength = Object.keys(event.data.playerItems).length;
          if (playerItemsLength > 0) {
            for (let i = 0; i < playerItemsLength; i++) {
              if (!items.includes(event.data.playerItems[i]["id"])) {
                let item = {
                  id: event.data.playerItems[i]["id"],
                  name: event.data.playerItems[i]["name"],
                  description: event.data.playerItems[i]["description"],
                  usable: event.data.playerItems[i]["usable"],
                  weight: event.data.playerItems[i]["weight"],
                  category: event.data.playerItems[i]["category_id"],
                  max_quantity: event.data.playerItems[i]["max_quantity"],
                  max_stack_size: event.data.playerItems[i]["max_stack_size"],
                };
                items.push(event.data.playerItems[i]["id"]);
                itemsStore.addItem("playerItems", item);
                // console.log(`Added item: ${item.name}`);
              }
              if (event.data.playerItems[i]["key"] != null) {
                itemsStore.addMetadata(event.data.playerItems[i]["id"], event.data.playerItems[i]["key"], event.data.playerItems[i]["value"]);
              }
            }
          }
        }

        if (typeof event.data.otherItems !== "undefined" && event.data.otherItems !== null) {
          const otherItemsLength = Object.keys(event.data.otherItems).length;
          for (let i = 0; i < otherItemsLength; i++) {
            if (!items.includes(event.data.otherItems[i]["id"])) {
              let item = {
                id: event.data.otherItems[i]["id"],
                name: event.data.otherItems[i]["name"],
                usable: event.data.otherItems[i]["usable"],
                weight: event.data.otherItems[i]["weight"],
                category: event.data.otherItems[i]["category_id"],
                max_quantity: event.data.otherItems[i]["max_quantity"],
                max_stack_size: event.data.otherItems[i]["max_stack_size"],
              };
              items.push(event.data.otherItems[i]["id"]);
              itemsStore.addItem("playerItems", item);
            }
            if (event.data.otherItems[i]["key"] != null) {
              itemsStore.addMetadata(event.data.otherItems[i]["id"], event.data.playerItems[i]["key"], event.data.playerItems[i]["value"]);
            }
          }
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
