<template>
    <div class="absolute z-50 w-full h-full bg-zinc-800 bg-opacity-90" @click="handleItemPopup()"
        v-show="activeItem?.key">
    </div>
    <Transition name="fade">
        <div class="absolute z-50 top-1/2 left-1/2 -translate-x-1/2 -translate-y-1/2 bg-zinc-900 p-10 rounded-md"
            v-if="activeItem?.key">
            <div class="text-white text-center">{{ activeItem.items?.length > 0 ? activeItem.items[0].displayName : activeItem.item.displayName }}</div>
            <div class="text-sm text-gray-400 text-center mt-2" v-if="activeItem?.item?.metadata?.display">{{ activeItem.item.metadata.display }}</div>
            <div
                class="bg-red-900 hover:bg-red-600 text-white font-bold py-2 px-4 border border-red-900 rounded w-80 text-center mb-6 mt-4">
                USE</div>
            <div
                class="bg-red-900 hover:bg-red-600 text-white font-bold py-2 px-4 border border-red-900 rounded w-80 text-center">
                GIVE</div>
        </div>
    </Transition>
</template>

<script setup>
const props = defineProps({
    activeItem: {
        type: Object,
        required: true
    }
})

const emit = defineEmits(['close'])

const handleItemPopup = () => {
    emit('close')
}
</script>
