<template>
    <div class="flex items-center justify-center">
        <Transition :name="`slide-${side}`">
            <div :class="`text-gray-100 bg-black noscrollbar overflow-y-scroll select-none rounded-md`"
                v-if="activeRightClickItem?.items" style="max-height: 50vh;">
                <div v-for="(subslot, key) in activeRightClickItem.items" :key="'playersubslot' + key + side"
                    @click.left="leftClick('subitem' + side + key, subslot)" @mousedown.left="startDrag($event, key)"
                    :class="`m-2 p-2 rounded-md bg-zinc-600 hover:bg-zinc-400 items-center justify-center`">
                    <div class="w-8 aspect-square text-center relative inline-block align-middle" :class="subslot?.metadata?.display ? `mr-2` : 'mr-0'">
                        <img :src="`/images/items/${subslot.name}.png`"/>
                    </div>
                    <div :class="`inline-block align-middle text-xs`"
                        style="max-width:160px;" v-if="subslot?.metadata?.display">
                        <span v-if="subslot?.metadata?.display">{{ subslot.metadata.display }}</span>
                    </div>
                </div>
            </div>
        </Transition>
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

const emit = defineEmits(['submit', 'transfer', 'dragging', 'dropped'])

const isDragging = ref(false);
const draggingIndex = ref(null);
const isShielded = ref(false);

const leftClick = (key, item) => {
    if (props.side == 'right' || !item?.usable) return
    emit('submit', key, item)
}

const startDrag = (event, index) => {
    isDragging.value = true;
    emit('dragging', true);
    draggingIndex.value = index;

    // Clone the the dom node
    const originalBox = event.currentTarget.querySelector('img');
    const clone = originalBox.cloneNode(true);
    clone.id = 'ghost';
    clone.classList.add('ghost');
    clone.style.width = '90px';
    clone.style.height = '90px';
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
                    if (dropZone.id == 'dropit') {
                        emit('dropped', dropZone.id, [props.activeRightClickItem.items[draggingIndex.value]])
                    } else {
                        emit('transfer', dropZone.id, [props.activeRightClickItem.items[draggingIndex.value]])
                    }
                }
            });

            clone.parentNode.removeChild(clone);
        }

        const shieldinv = document.querySelectorAll('.shieldinv');
        shieldinv.forEach(shield => shield.style.display = 'none')


        isShielded.value = false;
        isDragging.value = false;

        emit('dragging', false);

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