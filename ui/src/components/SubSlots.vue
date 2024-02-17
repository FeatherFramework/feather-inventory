<template>
    <div class="flex items-center justify-center">
        <div :class="`text-gray-100 bg-zinc-800 noscrollbar overflow-y-scroll select-none rounded-${side=='right' ? 'l' : 'r'}-md`"
            v-show="activeRightClickItem?.items" style="max-height: 50vh;">
            <div v-for="(subslot, key) in activeRightClickItem.items" :key="'playersubslot' + key + side"
                @click.left="leftClick('subitem' + side + key, subslot)"
                @mousedown.left="startDrag($event, key)"
                :class="`m-2 p-2 rounded-md bg-zinc-600 hover:bg-zinc-400 items-center justify-center`" >
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
import { ref } from 'vue';

const props = defineProps({
    activeRightClickItem: {
        type: Object,
        required: true
    },
    side: {
        type: String,
        required: true
    },
    id: {
        type: Number,
        required: true
    }
})

const emit = defineEmits(['submit', 'transfer'])

const isDragging = ref(false);
const draggingIndex = ref(null);
const isShielded = ref(false);

const leftClick = (key, item) => {
    emit('submit', key, item)
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
                    // TODO: Dont allow transfer to the SAME inventory!
                    emit('transfer', dropZone.id, [props.activeRightClickItem.items[draggingIndex.value]])
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



</script>
<style scoped>
.noscrollbar::-webkit-scrollbar {
    display: none !important;
}
</style>
  