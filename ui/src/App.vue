<template>
  <div id="content" class="relative bg-gray-900 left-0 right-0 mx-auto px-10" v-if="visible || devmode">
    <div class="absolute right-2 top-0 text-2xl text-white" @click="closeApp">&times;</div>
    <nav class="w-full text-center text-white">
      <router-link to="/">Home</router-link> |
      <router-link to="/about">About</router-link>
    </nav>
    <router-view />
  </div>
</template>

<script setup>
  import api from "./api";
  import { ref, onMounted, onUnmounted } from "vue";
  import { useSessionStore } from "@/stores/session";
  import { useItemsStore } from "@/store/items";
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
        console.log(JSON.stringify(event.data.items));
        visible.value = event.data.visible;
        sessionStore.storeMaxWeight(event.data.maxWeight);
        sessionStore.storeMaxItemSlots(event.data.items.maxSlots);
        sessionStore.storeInventoryId(event.data.playerInventory);
        sessionStore.storeOtherInventoryId(event.data.otherInventory);
        itemsStore.storePlayerItems(event.data.playerItems);
        itemsStore.storeOtherItems(event.data.otherItems);
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
