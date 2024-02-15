<template>
    <div class="flex items-center justify-center">
        <div :class="`text-gray-100 bg-zinc-800 noscrollbar overflow-y-scroll select-none rounded-${side=='right' ? 'l' : 'r'}-md`"
            v-show="activeRightClickItem?.items" style="max-height: 50vh;">
            <div v-for="(subslot, key) in activeRightClickItem.items" :key="'playersubslot' + key + side"
                @click.left="leftClick('subitem' + side + key, subslot)"
                :class="`m-2 p-2 rounded-md bg-zinc-600 hover:bg-zinc-400 items-center justify-center`">
                <div class="w-8 aspect-square text-center relative inline-block align-middle">
                    <img :src="`/images/items/${subslot.name}.png`" />
                </div>
                <div :class="`inline-block align-middle p${side=='right' ? 'r' : 'l'}-2 text-xs`" style="max-width:160px;"
                    v-if="subslot?.metadata?.display">
                    <span v-if="subslot?.metadata?.display">{{ subslot.metadata.display }}</span>
                </div>
            </div>
        </div>
    </div>
</template>
  
<script setup>
import _ from 'lodash';

const props = defineProps({
    activeRightClickItem: {
        type: Object,
        required: true
    },
    side: {
        type: String,
        required: true
    }
})
const emit = defineEmits(['submit'])

const leftClick = (key, item) => {
    emit('submit', key, item)
}



</script>
<style scoped>
.noscrollbar::-webkit-scrollbar {
    display: none !important;
}</style>
  