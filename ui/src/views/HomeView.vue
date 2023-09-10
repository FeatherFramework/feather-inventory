<template>
  <div class="text-gray-100">
    <div class="mb-10">
      <dl>
        <div class="flex">
          <dt>Max Weight:</dt>
          <dd class="ml-3">{{ maxWeight }}</dd>
        </div>
        <div class="flex">
          <dt>Max Item Slots:</dt>
          <dd class="ml-3">{{ maxItemSlots }}</dd>
        </div>
        <div class="flex">
          <dt>Inventory ID:</dt>
          <dd class="ml-3">{{ inventoryId }}</dd>
        </div>
        <div class="flex">
          <dt>Other Inventory ID:</dt>
          <dd class="ml-3">{{ otherInventoryId }}</dd>
        </div>
      </dl>
    </div>

    <div v-if="playerItems.length > 0">
      <p>Player Inventory:</p>
      <ul>
        <li v-for="item in playerItems" :key="item.id">
          {{ item.id }}
          - {{ item.name }} - {{ item.usable }} - {{ item.weight }} - {{ item.category }} - {{ item.max_quantity }} - {{ item.max_stack_size }}
          <ul v-if="hasMetadata(item.id)">
            <li v-for="(value, key) in itemsStore.getMetadata(item.id)" :key="key">{{ key }}: {{ value }}</li>
          </ul>
        </li>
      </ul>
    </div>

    <div v-if="otherItems.length > 0" class="mb-10">
      <p>Other Inventory:</p>
      <ul>
        <li v-for="item in otherItems" :key="item.id">
          {{ item.id }}
          - {{ item.name }} - {{ item.usable }} - {{ item.weight }} - {{ item.category }} - {{ item.max_quantity }} - {{ item.max_stack_size }}
          <ul v-if="hasMetadata(item.id)">
            <li v-for="(value, key) in itemsStore.getMetadata(item.id)" :key="key">{{ key }}: {{ value }}</li>
          </ul>
        </li>
      </ul>
    </div>
  </div>
</template>

<script setup>
  import { computed } from "vue";
  import { storeToRefs } from "pinia";
  import { useSessionStore } from "@/stores/session";
  import { useItemsStore } from "@/stores/items";

  const sessionStore = useSessionStore();
  const { maxWeight, maxItemSlots, inventoryId, otherInventoryId } = storeToRefs(sessionStore);

  const itemsStore = useItemsStore();
  const { playerItems, otherItems } = storeToRefs(itemsStore);

  const hasMetadata = (id) => {
    return Object.keys(itemsStore.getMetadata(id)).length > 0;
  };
</script>
