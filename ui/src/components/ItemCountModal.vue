<template>
    <div class="absolute z-50 w-full h-full bg-zinc-800 bg-opacity-90" @click="handleItemPopup()"
        v-show="activeItem?.id">
    </div>
    <div class="absolute z-50 top-1/2 left-1/2 -translate-x-1/2 -translate-y-1/2 bg-zinc-900 p-10 rounded-md"
        v-if="activeItem?.id">
        <div class="text-white text-center mb-4">{{ activeItem.items[0].displayName }}</div>
        <input
            class="bg-zinc-400 appearance-none border-2 border-zinc-400 rounded w-full py-2 px-4 text-gray-700 leading-tight focus:outline-none focus:bg-zinc-300 focus:border-red-700 mb-6"
            :min="minAmount" :max="maxAmount" type="number" v-model="amount">
        <div class="bg-red-900 hover:bg-red-600 text-white font-bold py-2 px-4 border border-red-900 rounded w-80 text-center"
            @click="handleAmountSubmit">{{ buttonText }}</div>

        <div v-if="error.active" class="text-red-600 text-center mt-10 text-md">
            {{ error.message }}
        </div>
    </div>
</template>

<script setup>
import { ref, reactive } from 'vue';

const props = defineProps({
    activeItem: {
        type: Object,
        required: true
    },
    buttonText: {
        type: String,
        required: true
    }
})

const error = reactive({
    active: false,
    message: ''
})

const amount = ref(props.activeItem?.items?.length || 1)
const minAmount = ref(1)
const maxAmount = ref(props.activeItem?.items?.length || 1)

const emit = defineEmits(['close', 'submit'])

const handleItemPopup = () => {
    emit('close')
}

const handleAmountSubmit = () => {
    error.active = false
    error.message = ""

    // input validations
    if (amount.value < minAmount.value || amount.value > maxAmount.value) {
        error.active = true
        error.message = "Invalid Amount"
        return
    }

    emit('submit', amount.value)
}

</script>
