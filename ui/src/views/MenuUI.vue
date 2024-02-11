<template>
    <div class="flow-root p-4">
        <InventorySlate :inventory="playerInventory" :options="globalOptions" :side="'left'" class="float-left relative"></InventorySlate>
        <InventorySlate :inventory="otherIventory" v-if="target != 'player'" :options="globalOptions" :side="'right'" class="float-right relative"></InventorySlate>
    </div>
</template>
  
<script setup>
import InventorySlate from '@/components/InventorySlate.vue';

const props = defineProps({
    playerInventory: {
        type: Object,
        required: true
    },
    otherIventory: {
        type: Object,
        required: true
    },
    globalOptions: {
        type: Object,
        required: true
    },
    target: {
        type: String,
        required: true
    }
})
</script>
  