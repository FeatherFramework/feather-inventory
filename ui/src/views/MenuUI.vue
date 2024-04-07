<template>
    <div class="flow-root p-4">
        <InventorySlate :inventory="playerInventory" :options="globalOptions" :side="'left'" class="float-left relative"
            :player-display="playerDisplay" @transfer="handleTransfer" @dragging="handleDrag" @itemAction="handleItemAction" @dropped="handleDropped"></InventorySlate>
        <div class="absolute bottom-14 left-1/2 -translate-x-1/2">
            <Transition name="scale">
                <DropItem v-if="showDrop"></DropItem>
            </Transition>
        </div>
        <InventorySlate :inventory="otherIventory" v-if="target != 'player'" :options="globalOptions" :side="'right'"
            class="float-right relative" @transfer="handleTransfer" @dragging="handleDrag"></InventorySlate>
    </div>
</template>

<script setup>
import InventorySlate from "@/components/InventorySlate.vue";
import DropItem from "@/components/DropItem.vue";
import { ref } from "vue";

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

const showDrop = ref(false);
const delay = ref(null);

const emit = defineEmits(['transfer', 'itemAction', 'dropped'])
const handleTransfer = (id, items) => {
    emit('transfer', id, items)
}

const handleItemAction = (actionData) => {
    emit('itemAction', actionData);
}

const handleDropped = (id, items) => {
    emit('dropped', id, items)
}

const handleDrag = (toggle) => {
    if (delay.value !== null) {
        clearTimeout(delay.value);
    }

    if (toggle == true) {
        delay.value = setTimeout(() => {
            showDrop.value = toggle
        }, 100);
    } else {
        showDrop.value = toggle
    }
}
</script>