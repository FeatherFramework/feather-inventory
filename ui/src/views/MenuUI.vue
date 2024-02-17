<template>
    <div class="flow-root p-4">
        <InventorySlate :inventory="playerInventory" :options="globalOptions" :side="'left'" class="float-left relative" :player-display="playerDisplay" @transfer="handleTransfer"></InventorySlate>
        <InventorySlate :inventory="otherIventory" v-if="target != 'player'" :options="globalOptions" :side="'right'" class="float-right relative" @transfer="handleTransfer"></InventorySlate>
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
    },
    playerDisplay: {
        type: Object,
        required: true
    }
})

const emit = defineEmits(['transfer'])
const handleTransfer = (id, items) => {
    emit('transfer', id, items)
}

</script>
  