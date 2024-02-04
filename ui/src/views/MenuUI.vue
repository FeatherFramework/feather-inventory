<template>
    <div class="text-gray-100">
        <div class="mb-10">
            <dl>
                <div class="flex">
                    <dt>Max Weight:</dt>
                    <dd class="ml-3">{{ globalOptions.maxWeight }}</dd>
                </div>
                <div class="flex">
                    <dt>Max Item Slots:</dt>
                    <dd class="ml-3">{{ globalOptions.maxItemSlots }}</dd>
                </div>
                <div class="flex">
                    <dt>Categories:</dt>
                    <dd class="ml-3">{{ globalOptions.categories }}</dd>
                </div>
            </dl>
        </div>

        <div v-if="playerInventory.items.length > 0">
            <p>Player Inventory ({{ playerInventory.id }}):</p>
            <p>Name: {{ playerInventory.name }}</p>
            <ul>
                <li v-for="(slot, key) in playerInventory.items" :key="'playerslot' + key">
                    <p>{{ slot.key }}</p>
                    <ul>
                        <li v-for="(item, itemkey) in slot.items" :key="'playeritem' + itemkey">
                            {{ item.length }}
                        </li>
                    </ul>


                </li>
            </ul>
        </div>

        <div v-if="otherIventory.items.length > 0" class="mb-10">
            <p>Other Inventory ({{ otherIventory.id }}):</p>
            <p>Name: {{ otherIventory.name }}</p>
            <ul>
                <li v-for="item in otherIventory.items" :key="item.id">
                    {{ item }}
                </li>
            </ul>
        </div>
    </div>
</template>
  
<script setup>
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
  