<template>
    <div class="flow-root p-4">
        <InventorySlate :inventory="playerInventory" v-if="playerInventory.items.length > 0" :options="globalOptions" :side="'left'" class="float-left relative"></InventorySlate>
        <InventorySlate :inventory="otherIventory" v-if="otherIventory.items.length > 0" :options="globalOptions" :side="'right'" class="float-right relative"></InventorySlate>
    </div>
</template>
  
<script setup>
import InventorySlate from '@/components/InventorySlate.vue';

const props = defineProps({
    playerInventory: {
        type: Object,
        required: true,
        default: () => { }
    },
    otherIventory: {
        type: Object,
        required: true,
        default: () => { }
    },
    globalOptions: {
        type: Object,
        required: true,
        default: () => { }
    }
})
</script>
  