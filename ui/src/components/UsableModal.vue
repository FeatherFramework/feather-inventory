<template>
   <div class="absolute w-full h-full">
        <div class="absolute z-50 w-full h-full bg-zinc-800 bg-opacity-90" @click="handleItemPopup()" v-show="activeItem?.key">
        </div>
        <Transition name="fade">
            <div class="absolute z-50 top-1/2 left-1/2 -translate-x-1/2 -translate-y-1/2 bg-zinc-900 p-10 rounded-md"
                v-if="activeItem?.key">
                <div class="text-white text-center">{{ activeItem.items?.length > 0 ? activeItem.items[0].displayName : activeItem.item.displayName }}</div>
                <div class="text-sm text-gray-400 text-center mt-2" v-if="activeItem?.item?.metadata?.display">{{ activeItem.item.metadata.display }}</div>
                <div
                    class="bg-red-900 hover:bg-red-600 text-white font-bold py-2 px-4 border border-red-900 rounded w-80 text-center mb-6 mt-4" @click="handleItemUse">
                    USE</div>
                <div
                    class="bg-red-900 hover:bg-red-600 text-white font-bold py-2 px-4 border border-red-900 rounded w-80 text-center" @click="handleItemGive">
                    GIVE</div>
            </div>
        </Transition>
    </div>
</template>

<script setup>
const props = defineProps({
    activeItem: {
        type: Object,
        required: true
    }
})

const emit = defineEmits(['close', 'itemAction'])

const handleItemPopup = () => {
    emit('close')
}

const handleItemUse = () => {
    emit('itemAction', {
        item: props.activeItem.items?.length > 0 ? props.activeItem.items[0] : props.activeItem.item,
        action: 'use'
    })
}

const handleItemGive = () => {
    emit('itemAction', {
        item: props.activeItem.items?.length > 0 ? props.activeItem.items[0] : props.activeItem.item,
        action: 'give'
    })
}
</script>
