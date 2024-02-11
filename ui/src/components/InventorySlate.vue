<template>
    <div class="flex items-center justify-center">
        <div class="absolute z-50 w-full h-full bg-zinc-800 bg-opacity-40" @click="handleItemPopup()" v-show="activeLeftClickItem?.key || activeLeftClickSubItem?.key">
        </div>
        <div class="absolute z-50 top-1/2 left-1/2 -translate-x-1/2 -translate-y-1/2 bg-zinc-800 p-10"  v-if="activeLeftClickItem?.key">
            <div
                class="bg-blue-500 hover:bg-blue-700 text-white font-bold py-2 px-4 border border-blue-700 rounded w-80 text-center mb-6">
                Use</div>
            <div
                class="bg-blue-500 hover:bg-blue-700 text-white font-bold py-2 px-4 border border-blue-700 rounded w-80 text-center">
                Give</div>
        </div>

        <div class="absolute z-50 top-1/2 left-1/2 -translate-x-1/2 -translate-y-1/2 bg-zinc-800 p-10"  v-if="activeLeftClickSubItem?.key">
            <div
                class="bg-blue-500 hover:bg-blue-700 text-white font-bold py-2 px-4 border border-blue-700 rounded w-80 text-center mb-6">
                Use</div>
            <div
                class="bg-blue-500 hover:bg-blue-700 text-white font-bold py-2 px-4 border border-blue-700 rounded w-80 text-center">
                Give</div>
        </div>
        <SubSlots v-if="side == 'right'" :side="side" :activeRightClickItem="activeRightClickItem" @submit="handleSubItemClick"></SubSlots>
        <div class="text-gray-100 bg-zinc-800 p-6 min-h-full relative select-none  rounded-md"
            style="width: 500px; height: 70vh;">
            <h1 class="font-bold text-2xl text-center">{{ inventory.name }}</h1>
            <div class="mb-2 mt-10">
                <div class="flex items-center justify-center w-full">
                    <div class="flex w-full">
                        <div class="px-4 py-2 text-white bg-blue-500 rounded-l-md flex-none w-14" @click="prevString()">
                            <svg class="w-6 h-6" xmlns="http://www.w3.org/2000/svg" viewBox="0 0 448 512">
                                <path fill="#ffffff"
                                    d="M9.4 233.4c-12.5 12.5-12.5 32.8 0 45.3l160 160c12.5 12.5 32.8 12.5 45.3 0s12.5-32.8 0-45.3L109.2 288 416 288c17.7 0 32-14.3 32-32s-14.3-32-32-32l-306.7 0L214.6 118.6c12.5-12.5 12.5-32.8 0-45.3s-32.8-12.5-45.3 0l-160 160z" />
                            </svg>
                        </div>
                        <div class="px-4 py-2 bg-zinc-600 grow text-center capitalize">{{ activeCategory.name }}</div>
                        <div class="px-4 py-2 text-white bg-blue-500 rounded-r-md flex-none w-14" @click="nextString()">
                            <svg class="w-6 h-6" xmlns="http://www.w3.org/2000/svg" viewBox="0 0 448 512">
                                <path fill="#ffffff"
                                    d="M438.6 278.6c12.5-12.5 12.5-32.8 0-45.3l-160-160c-12.5-12.5-32.8-12.5-45.3 0s-12.5 32.8 0 45.3L338.8 224 32 224c-17.7 0-32 14.3-32 32s14.3 32 32 32l306.7 0L233.4 393.4c-12.5 12.5-12.5 32.8 0 45.3s32.8 12.5 45.3 0l160-160z" />
                            </svg>
                        </div>
                    </div>
                </div>
            </div>

            <hr class="mb-10" />
            <div :class="`relative grid grid-flow-row-dense grid-cols-5 gap-2 select-none ${options.maxItemSlots >= 5 ? 'overflow-y-scroll pr-4' : ''}`"
                style="height: 40%;">
                <div v-for="(slot, key) in filteredList" :key="'playerslot' + key + side"
                    class="aspect-square bg-zinc-600 text-center relative rounded-md hover:bg-zinc-200 hover:cursor-pointer"
                    @mouseover="setActiveData(true, slot[0])" @mouseleave="setActiveData(false)"
                    @click.left="handleItemClick('left', 'playerslot' + key + side, slot)"
                    @click.right="handleItemClick('right', 'playerslot' + key + side, slot)">
                    <img :src="`/images/items/${slot[0].name}.png`" />
                    <div
                        class="w-8 h-8 absolute right-1 bottom-1 font-bold bg-white text-black rounded-full flex justify-center items-center">
                        <p>{{ slot.length }}</p>
                    </div>
                </div>
                <div v-for="n in options.maxItemSlots - inventory.items.length" :key="'emptyslot' + n"
                    class="aspect-square bg-zinc-600 text-center relative rounded-md">
                </div>
            </div>

            <hr class="mt-10" />
            <div class="text-center mt-2">
                <h2 class="text-xl">{{ activeName }}</h2>
                <p>{{ activeDescription }}</p>
            </div>
        </div>
        <SubSlots v-if="side == 'left'" :side="side" :activeRightClickItem="activeRightClickItem" @submit="handleSubItemClick"></SubSlots>
    </div>
</template>
  
<script setup>
import { onMounted, ref, watch } from 'vue';
import _ from 'lodash';

import SubSlots from '@/components/SubSlots.vue'

const props = defineProps({
    inventory: {
        type: Object,
        required: true
    },
    options: {
        type: Object,
        required: true
    },
    side: {
        type: String,
        required: true
    }
})

const availableCategories = ref([]);
const currentCategoryIndex = ref(0);
const filteredList = ref([])

const activeDescription = ref('')
const activeName = ref('')
const activeCategory = ref({
    name: 'loading'
})

const activeLeftClickItem = ref({})
const activeRightClickItem = ref({})

const activeLeftClickSubItem = ref({})

onMounted(() => {
    availableCategories.value = [
        ...[{
            name: 'all'
        }],
        ...props.options.categories
    ]

    activeCategory.value = availableCategories.value[0];
})

watch(activeCategory, async (change) => {
    filteredList.value = _.filter(props.inventory.items, (item) => {
        if (typeof change.id == 'undefined' || change.id == null) {
            return true
        }

        return item[0].category == change.id
    });
})

const handleItemClick = (button, key, items) => {
    if (button == 'left') {
        activeLeftClickItem.value = {
            key: key,
            items: items
        }
    } else {
        if (activeRightClickItem?.value?.key && key == activeRightClickItem.value.key) {
            activeRightClickItem.value = {}
        } else {
            activeRightClickItem.value = {
                key: key,
                items: items
            }
        }
    }
}

const handleSubItemClick = (key, item) => {
    activeLeftClickSubItem.value = {
        key: key,
        item: item
    }
}

const handleItemPopup = () => {
    activeLeftClickItem.value = {}
    activeLeftClickSubItem.value = {}
}

const setActiveData = (active, slot) => {
    if (active) {
        activeDescription.value = slot.description
        activeName.value = slot.displayName
    } else {
        activeDescription.value = ''
        activeName.value = ''
    }
}

function prevString() {
    currentCategoryIndex.value = (currentCategoryIndex.value - 1 + availableCategories.value.length) % availableCategories.value.length;
    activeCategory.value = availableCategories.value[currentCategoryIndex.value];
}

function nextString() {
    currentCategoryIndex.value = (currentCategoryIndex.value + 1) % availableCategories.value.length;
    activeCategory.value = availableCategories.value[currentCategoryIndex.value];
}



</script>
<style scoped>
/* width */
::-webkit-scrollbar {
    width: 2px;
}

/* Track */
::-webkit-scrollbar-track {
    background: #f1f1f1;
}

/* Handle */
::-webkit-scrollbar-thumb {
    background: #888;
}

/* Handle on hover */
::-webkit-scrollbar-thumb:hover {
    background: #555;
}

.noscrollbar::-webkit-scrollbar {
    display: none !important;
}</style>
  