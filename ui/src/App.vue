<script setup>
import api from './api';
import { computed, onMounted, onUnmounted, reactive, ref } from 'vue';
import '@/assets/tailwind.css';
import LedgerBook from '@/components/LedgerBook.vue';
import UsableModal from '@/components/UsableModal.vue';
import DropItem from '@/components/DropItem.vue';

const visible = ref(false);
const devmode = ref(false);

function makeBook(footerLabel) {
  return reactive({
    title: '',
    subtitle: '',
    footerLabel,
    capacity: 0,
    inventoryId: null,
    ignoreLimits: 0,
    items: [],
    activeCategoryId: null,
    selectedIndex: -1,
  });
}

const player = makeBook('CARRYING');
const other = makeBook('STORED');
const hasOther = computed(() => other.inventoryId !== null);

const rawCategories = ref([]);
const categoryOptions = computed(() => [
  { id: null, label: 'ALL' },
  ...rawCategories.value.map((c) => ({ id: c.id, label: String(c.name).toUpperCase() })),
]);

// Single global drag pointer shared across both books -- lets a drag that
// started in one book highlight valid drop targets in the other.
const drag = ref(null); // { book: 'player' | 'other', slot, itemId }
const hover = ref(null); // { book, slot }
const showDropZone = ref(false);
let dropZoneTimer = null;

const usableItem = ref(null); // item passed to UsableModal, or null

function bookByKey(key) {
  return key === 'player' ? player : other;
}

// Books are "paired" for drag purposes only when both are actually open --
// matches the design's "source and destination must both be open" rule.
function dragArmedFor(bookKey) {
  return !!drag.value && (drag.value.book === bookKey || hasOther.value);
}

const onMessage = (event) => {
  const data = event.data;
  if (data.type !== 'toggleInventory') return;

  visible.value = data.visible;
  rawCategories.value = data.categories || [];

  player.title = 'PERSONAL EFFECTS';
  player.subtitle = data.player?.characterName || '';
  player.capacity = Number(data.maxSlots) || 0;
  player.inventoryId = data.playerInventory;
  player.ignoreLimits = data.playerIgnoreLimits || 0;
  player.items = data.playerItems || [];
  player.activeCategoryId = null;
  player.selectedIndex = -1;

  if (data.otherItems != null) {
    other.title = String(data.otherName || 'STORAGE').toUpperCase();
    other.subtitle = '';
    other.capacity = Number(data.maxSlots) || 0;
    other.inventoryId = data.otherInventory;
    other.ignoreLimits = data.otherIgnoreLimits || 0;
    other.items = data.otherItems;
    other.activeCategoryId = null;
    other.selectedIndex = -1;
  } else {
    other.inventoryId = null;
    other.items = [];
  }
};

onMounted(() => {
  window.addEventListener('message', onMessage);
  window.addEventListener('keydown', onKeydown);
  window.addEventListener('mouseup', onGlobalMouseUp);
});

onUnmounted(() => {
  window.removeEventListener('message', onMessage);
  window.removeEventListener('keydown', onKeydown);
  window.removeEventListener('mouseup', onGlobalMouseUp);
});

const onKeydown = (event) => {
  if (!visible.value) return;
  if (event.code === 'Escape') closeApp();
};

const closeApp = () => {
  visible.value = false;
  drag.value = null;
  hover.value = null;
  usableItem.value = null;
  api.post('Feather:Inventory:NuiCloseInventory', {}).catch((e) => console.log(e.message));
};

// --- Drag and drop -------------------------------------------------------

function onCellMouseDown(bookKey, slotIndex) {
  const book = bookByKey(bookKey);
  const cellHasItem = book.items.some((i) => i.slot_index === slotIndex);
  if (!cellHasItem) return;

  book.selectedIndex = slotIndex;
  drag.value = { book: bookKey, slot: slotIndex };

  if (dropZoneTimer) clearTimeout(dropZoneTimer);
  dropZoneTimer = setTimeout(() => {
    showDropZone.value = true;
  }, 100);
}

function onCellMouseEnter(bookKey, slotIndex) {
  if (!drag.value) return;
  if (!dragArmedFor(bookKey)) return;
  hover.value = { book: bookKey, slot: slotIndex };
}

async function onCellMouseUp(bookKey, slotIndex) {
  const d = drag.value;
  if (!d) {
    clearDrag();
    return;
  }
  // Resolve validity from the saved pointer `d` before clearDrag() nulls
  // the shared drag state out from under it -- checking dragArmedFor()
  // *after* clearing always read "no drag in progress" and silently
  // dropped every move.
  const armed = d.book === bookKey || hasOther.value;
  const droppedOnSelf = d.book === bookKey && d.slot === slotIndex;
  clearDrag();

  if (!armed || droppedOnSelf) return;

  const fromBook = bookByKey(d.book);
  const toBook = bookByKey(bookKey);
  const movingStack = fromBook.items.filter((i) => i.slot_index === d.slot);
  if (movingStack.length === 0) return;

  const itemId = movingStack[0].id;

  // Optimistic local swap/move so it feels instant; reconciled from the
  // server response right after (or rolled back on error).
  const occupying = toBook.items.filter((i) => i.slot_index === slotIndex);
  for (const item of movingStack) item.slot_index = slotIndex;
  for (const item of occupying) item.slot_index = d.slot;
  if (d.book !== bookKey) {
    fromBook.items = fromBook.items.filter((i) => !movingStack.includes(i));
    toBook.items.push(...movingStack);
    if (occupying.length) {
      toBook.items = toBook.items.filter((i) => !occupying.includes(i));
      fromBook.items.push(...occupying);
    }
  }
  toBook.selectedIndex = slotIndex;

  try {
    const { data } = await api.post('Feather:Inventory:MoveItem', {
      itemId,
      toInventory: toBook.inventoryId,
      toSlot: slotIndex,
    });
    if (data?.error) {
      rollbackMove();
      return;
    }
    if (data?.sourceItems) fromBook.items = data.sourceItems;
    if (data?.targetItems) toBook.items = data.targetItems;
  } catch (e) {
    console.log(e.message);
    rollbackMove();
  }

  function rollbackMove() {
    for (const item of movingStack) item.slot_index = d.slot;
    for (const item of occupying) item.slot_index = slotIndex;
  }
}

function clearDrag() {
  drag.value = null;
  hover.value = null;
  if (dropZoneTimer) clearTimeout(dropZoneTimer);
  showDropZone.value = false;
}

function onGlobalMouseUp() {
  // Released outside any compartment (and outside the drop zone, which
  // stops its own mouseup event) -- a no-op drag per the design.
  if (drag.value) clearDrag();
}

// --- Ground drop -----------------------------------------------------------

function onDropZoneRelease(event) {
  event.stopPropagation();
  const d = drag.value;
  clearDrag();
  if (!d) return;

  const book = bookByKey(d.book);
  const stack = book.items.filter((i) => i.slot_index === d.slot);
  if (stack.length === 0) return;

  api
    .post('Feather:Inventory:DropItems', { items: stack.map((i) => i.id) })
    .then(({ data }) => {
      if (data?.error) return;
      if (data?.inv?.sourceItems) book.items = data.inv.sourceItems;
    })
    .catch((e) => console.log(e.message));
}

// --- Item use / give ---------------------------------------------------

function onCellDblClick(bookKey, slotIndex) {
  const book = bookByKey(bookKey);
  const stack = book.items.filter((i) => i.slot_index === slotIndex);
  if (stack.length === 0) return;
  usableItem.value = { key: stack[0].id, items: stack };
}

function onUsableAction({ item, action }) {
  usableItem.value = null;
  if (action === 'use') {
    api.post('Feather:Inventory:UseItem', { itemId: item.id, itemName: item.name }).catch((e) => console.log(e.message));
  } else if (action === 'give') {
    api.post('Feather:Inventory:GiveItem', { item }).catch((e) => console.log(e.message));
  }
}
</script>

<template>
  <div v-if="visible || devmode" class="ledger-overlay">
    <div class="ledger-vignette"></div>
    <div class="ledger-close" @click="closeApp">&times;</div>

    <div class="ledger-books" :class="{ paired: hasOther }">
      <LedgerBook
        title="PERSONAL EFFECTS"
        :subtitle="player.subtitle"
        footer-label="CARRYING"
        :capacity="player.capacity"
        :items="player.items"
        :categories="categoryOptions"
        v-model:active-category-id="player.activeCategoryId"
        v-model:selected-index="player.selectedIndex"
        :paired="hasOther"
        :drag-slot="drag && drag.book === 'player' ? drag.slot : -1"
        :drag-armed="dragArmedFor('player')"
        :hover-slot="hover && hover.book === 'player' ? hover.slot : -1"
        @cell-mouse-down="(i) => onCellMouseDown('player', i)"
        @cell-mouse-enter="(i) => onCellMouseEnter('player', i)"
        @cell-mouse-up="(i) => onCellMouseUp('player', i)"
        @cell-dbl-click="(i) => onCellDblClick('player', i)"
      />

      <LedgerBook
        v-if="hasOther"
        :title="other.title"
        :subtitle="other.subtitle"
        footer-label="STORED"
        :capacity="other.capacity"
        :items="other.items"
        :categories="categoryOptions"
        v-model:active-category-id="other.activeCategoryId"
        v-model:selected-index="other.selectedIndex"
        paired
        :drag-slot="drag && drag.book === 'other' ? drag.slot : -1"
        :drag-armed="dragArmedFor('other')"
        :hover-slot="hover && hover.book === 'other' ? hover.slot : -1"
        @cell-mouse-down="(i) => onCellMouseDown('other', i)"
        @cell-mouse-enter="(i) => onCellMouseEnter('other', i)"
        @cell-mouse-up="(i) => onCellMouseUp('other', i)"
        @cell-dbl-click="(i) => onCellDblClick('other', i)"
      />
    </div>

    <div v-if="hasOther" class="ledger-hint">Drag an entry from one book to the other to move it &bull; ESC closes both</div>

    <div v-if="showDropZone" class="ledger-dropzone" @mouseup="onDropZoneRelease">
      <DropItem />
    </div>

    <UsableModal
      v-if="usableItem"
      :active-item="usableItem"
      @close="usableItem = null"
      @item-action="onUsableAction"
    />
  </div>
</template>

<style>
@font-face {
  font-family: 'Playfair Display';
  src: url('@/assets/fonts/ledger/playfair-display-variable.woff2') format('woff2');
  font-weight: 500 900;
  font-display: swap;
}

@font-face {
  font-family: 'Old Standard TT';
  src: url('@/assets/fonts/ledger/old-standard-tt-regular-400.woff2') format('woff2');
  font-weight: 400;
  font-style: normal;
  font-display: swap;
}

@font-face {
  font-family: 'Old Standard TT';
  src: url('@/assets/fonts/ledger/old-standard-tt-regular-700.woff2') format('woff2');
  font-weight: 700;
  font-style: normal;
  font-display: swap;
}

@font-face {
  font-family: 'Old Standard TT';
  src: url('@/assets/fonts/ledger/old-standard-tt-italic-400.woff2') format('woff2');
  font-weight: 400;
  font-style: italic;
  font-display: swap;
}

body {
  margin: 0;
  overflow: hidden;
}

#app {
  touch-action: manipulation;
  -webkit-font-smoothing: antialiased;
  -moz-osx-font-smoothing: grayscale;
}

.ledger-overlay {
  position: fixed;
  inset: 0;
  display: flex;
  align-items: center;
  justify-content: center;
  background: rgba(18, 14, 10, 0.42);
  /* Design is authored for 1920x1080 -- scale the whole overlay to fit any
     viewport while keeping the book's proportions. */
  --ledger-scale: min(calc(100vw / 1920), calc(100vh / 1080));
}

.ledger-vignette {
  position: absolute;
  inset: 0;
  background: radial-gradient(ellipse at center, rgba(0, 0, 0, 0) 26%, rgba(0, 0, 0, 0.38) 100%);
  pointer-events: none;
}

.ledger-books {
  position: relative;
  display: flex;
  align-items: center;
  justify-content: center;
  transform: scale(var(--ledger-scale));
}

.ledger-books.paired {
  gap: 70px;
}

.ledger-hint {
  position: absolute;
  bottom: calc(52px * var(--ledger-scale, 1));
  left: 0;
  right: 0;
  text-align: center;
  font-family: 'Old Standard TT', serif;
  font-size: 16px;
  font-style: italic;
  color: #cbb894;
  pointer-events: none;
}

.ledger-close {
  position: absolute;
  top: 24px;
  right: 32px;
  font-size: 28px;
  color: #cbb894;
  cursor: pointer;
  z-index: 10;
}

.ledger-close:hover {
  color: #f0e6d2;
}

.ledger-dropzone {
  position: absolute;
  bottom: 40px;
  left: 50%;
  transform: translateX(-50%);
  z-index: 50;
}
</style>
