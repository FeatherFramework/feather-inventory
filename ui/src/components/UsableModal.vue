<template>
    <div class="absolute z-50 w-full h-full bg-zinc-800 bg-opacity-90" @click="handleItemPopup()"
        v-show="activeItem?.key">
    </div>
    <div class="absolute z-50 top-1/2 left-1/2 -translate-x-1/2 -translate-y-1/2 bg-zinc-900 p-10 rounded-md" v-if="activeItem?.key">
        <div
            class="bg-red-900 hover:bg-red-600 text-white font-bold py-2 px-4 border border-red-900 rounded w-80 text-center mb-6">
            USE</div>
        <div
            class="bg-red-900 hover:bg-red-600 text-white font-bold py-2 px-4 border border-red-900 rounded w-80 text-center">
            GIVE</div>
    </div>
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
