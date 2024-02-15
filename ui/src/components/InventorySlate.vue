<template>
    <div class="flex items-center justify-center">
        <div class="shieldinv absolute z-50 w-full h-full bg-zinc-800 bg-opacity-0" style="display:none;">
        </div>
        <UsableModal :active-item="activeLeftClickItem" @close="handleItemPopup"></UsableModal>
        <UsableModal :active-item="activeLeftClickSubItem" @close="handleItemPopup"></UsableModal>
        <SubSlots v-if="side == 'right'" :side="side" :activeRightClickItem="activeRightClickItem"
            @submit="handleSubItemClick"></SubSlots>
        <div class="text-gray-100 bg-zinc-800 p-6 min-h-full relative select-none rounded-md flex flex-col justify-between dropzone"
            :id="`dropzone-${side}`" style="width: 500px; height: 70vh;">
            <h1 class="font-bold text-2xl text-center">{{ inventory.name }}</h1>
            <div class="my-4">
                <div class="flex items-center justify-center w-full">
                    <div class="flex w-full">
                        <div class="flex justify-center items-center px-4 py-1 text-white bg-red-900 hover:bg-red-600 rounded-l-md flex-none w-14"
                            @click="prevString()">
                            <svg class="w-4 h-4" xmlns="http://www.w3.org/2000/svg" viewBox="0 0 448 512">
                                <path fill="#ffffff"
                                    d="M9.4 233.4c-12.5 12.5-12.5 32.8 0 45.3l160 160c12.5 12.5 32.8 12.5 45.3 0s12.5-32.8 0-45.3L109.2 288 416 288c17.7 0 32-14.3 32-32s-14.3-32-32-32l-306.7 0L214.6 118.6c12.5-12.5 12.5-32.8 0-45.3s-32.8-12.5-45.3 0l-160 160z" />
                            </svg>
                        </div>
                        <div class="px-4 py-1 bg-zinc-600 grow text-center capitalize">{{ activeCategory.name }}</div>
                        <div class="flex justify-center items-center px-4 py-1 text-white bg-red-900 hover:bg-red-600 rounded-r-md flex-none w-14"
                            @click="nextString()">
                            <svg class="w-4 h-4" xmlns="http://www.w3.org/2000/svg" viewBox="0 0 448 512">
                                <path fill="#ffffff"
                                    d="M438.6 278.6c12.5-12.5 12.5-32.8 0-45.3l-160-160c-12.5-12.5-32.8-12.5-45.3 0s-12.5 32.8 0 45.3L338.8 224 32 224c-17.7 0-32 14.3-32 32s14.3 32 32 32l306.7 0L233.4 393.4c-12.5 12.5-12.5 32.8 0 45.3s32.8 12.5 45.3 0l160-160z" />
                            </svg>
                        </div>
                    </div>
                </div>
            </div>

            <!-- <hr class="mb-10" /> -->
            <div :class="`relative grid grid-flow-row-dense grid-cols-5 gap-2 select-none ${options.maxItemSlots >= 5 ? 'overflow-y-scroll pr-4' : ''}`"
                style="height: 40%; min-height: 300px;">
                <div v-for="(slot, key) in filteredList" :key="'playerslot' + key + side"
                    class="aspect-square bg-zinc-600 text-center relative rounded-md hover:bg-zinc-200 hover:cursor-pointer"
                    @mousedown.left="startDrag($event, key)"
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

            <hr class="mt-4" />
            <div class="text-center mt-2 mb-auto noscrollbar overflow-y-scroll">
                <h2 class="text-lg font-bold">{{ activeName }}</h2>
                <p class="text-sm">{{ activeDescription }}</p>
            </div>

            <div class="footer h-20" v-if="side == 'left'">
                <hr class="mt-10" />
                <div class="flex items-center py-2 justify-between">
                    <div class="flex align-middle">
                        <div class="flex object align-middle mr-4" v-for="(currency, key) in currencies"
                            :key="key + 'moneyspot'">
                            <img class="w-6 h-6 align-middle" :src="currency.image" />
                            <div class="text-lg chinarocks align-middle ml-2">{{ currency.value }}</div>
                        </div>
                    </div>
                    <div>
                        ID: 2
                    </div>
                </div>
            </div>
        </div>
        <SubSlots v-if="side == 'left'" :side="side" :activeRightClickItem="activeRightClickItem"
            @submit="handleSubItemClick"></SubSlots>
    </div>
</template>
  
<script setup>
import { onMounted, ref, watch } from 'vue';
import _ from 'lodash';

import UsableModal from './UsableModal.vue';
import SubSlots from '@/components/SubSlots.vue'
import MoneyIcon from '@/assets/icons/money.png'
import GoldIcon from '@/assets/icons/gold.png'
import TokenIcon from '@/assets/icons/token.png'

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

const currencies = ref({
    money: {
        image: MoneyIcon,
        value: '$00.00'
    },
    gold: {
        image: GoldIcon,
        value: '00.00'
    },
    tokens: {
        image: TokenIcon,
        value: '00'
    }
})

const activeDescription = ref('')
const activeName = ref('')
const activeCategory = ref({
    name: 'loading'
})

const activeLeftClickItem = ref({})
const activeRightClickItem = ref({})

const activeLeftClickSubItem = ref({})

const isDragging = ref(false);
const isShielded = ref(false);
const draggingIndex = ref(null);

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

const startDrag = (event, index) => {
    isDragging.value = true;
    draggingIndex.value = index;

    // Clone the the dom node
    const originalBox = event.currentTarget.querySelector('img');
    const clone = originalBox.cloneNode(true);
    clone.id = 'ghost';
    clone.classList.add('ghost');
    document.body.appendChild(clone);

    document.addEventListener('mousemove', onDrag);
    document.addEventListener('mouseup', endDrag);
};

const onDrag = (event) => {
    if (isDragging.value) {
        const clone = document.getElementById('ghost');
        clone.style.left = (event.clientX - clone.offsetWidth / 2) + 'px';
        clone.style.top = (event.clientY - clone.offsetHeight / 2) + 'px';

        if (isShielded.value == false) {
            isShielded.value = true;
            const shieldinv = document.querySelectorAll('.shieldinv');
            shieldinv.forEach(shield => shield.style.display = 'block')
            clone.style.opacity = '.8'
        }
    }
};

const endDrag = () => {
    if (isDragging.value) {
        const clone = document.getElementById('ghost');
        if (clone) {
            const dropZones = document.querySelectorAll('.dropzone');
            dropZones.forEach(dropZone => {
                const dropZoneRect = dropZone.getBoundingClientRect();

                const ghostRect = clone.getBoundingClientRect();

                if (
                    ghostRect.left >= dropZoneRect.left &&
                    ghostRect.right <= dropZoneRect.right &&
                    ghostRect.top >= dropZoneRect.top &&
                    ghostRect.bottom <= dropZoneRect.bottom
                ) {
                    console.log('Item dropped into drop zone!', dropZone.id);
                    console.log(filteredList.value[draggingIndex.value][0].name, filteredList.value[draggingIndex.value].length);
                }
            });

            clone.parentNode.removeChild(clone);
        }

        const shieldinv = document.querySelectorAll('.shieldinv');
        shieldinv.forEach(shield => shield.style.display = 'none')


        isShielded.value = false;
        isDragging.value = false;
        document.removeEventListener('mousemove', onDrag);
        document.removeEventListener('mouseup', endDrag);
    }
};

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
    activeRightClickItem.value = {}
    currentCategoryIndex.value = (currentCategoryIndex.value - 1 + availableCategories.value.length) % availableCategories.value.length;
    activeCategory.value = availableCategories.value[currentCategoryIndex.value];
}

function nextString() {
    activeRightClickItem.value = {}
    currentCategoryIndex.value = (currentCategoryIndex.value + 1) % availableCategories.value.length;
    activeCategory.value = availableCategories.value[currentCategoryIndex.value];
}

</script>
<style scoped>
/* width */
::-webkit-scrollbar {
    width: 2px;
    display: block;
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
}

.ghost {
    pointer-events: none;
    position: absolute;
    opacity: 0;
    z-index: 99999;
}
</style>
  