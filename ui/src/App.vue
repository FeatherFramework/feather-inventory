<script setup>
import api from './api';
import { computed, onMounted, onUnmounted, reactive, ref } from 'vue';
import '@/assets/tailwind.css';
import LedgerBook from '@/components/LedgerBook.vue';
import ContextMenu from '@/components/ContextMenu.vue';
import ItemCountModal from '@/components/ItemCountModal.vue';

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

const contextMenu = ref(null); // { book, slot, x, y } | null

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
  contextMenu.value = null;
  quantityPrompt.value = null;
  api.post('Feather:Inventory:NuiCloseInventory', {}).catch((e) => console.log(e.message));
};

// --- Drag and drop -------------------------------------------------------

function onCellMouseDown(bookKey, slotIndex) {
  contextMenu.value = null;

  const book = bookByKey(bookKey);
  const cellHasItem = book.items.some((i) => i.slot_index === slotIndex);
  if (!cellHasItem) return;

  book.selectedIndex = slotIndex;
  drag.value = { book: bookKey, slot: slotIndex };
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
}

function onGlobalMouseUp() {
  // Released outside any compartment -- a no-op drag per the design.
  if (drag.value) clearDrag();
}

// --- Item use / give / drop ---------------------------------------------

// Double-click: immediate use, no confirmation -- only for items that are
// actually usable, per your call. Non-usable items just stay selected
// (mousedown already handled that).
function onCellDblClick(bookKey, slotIndex) {
  const book = bookByKey(bookKey);
  const stack = book.items.filter((i) => i.slot_index === slotIndex);
  if (stack.length === 0) return;
  const item = stack[0];
  if (!item.usable) return;

  api.post('Feather:Inventory:UseItem', { itemId: item.id, itemName: item.name }).catch((e) => console.log(e.message));
}

function onCellContextMenu(bookKey, slotIndex, event) {
  const book = bookByKey(bookKey);
  const cellHasItem = book.items.some((i) => i.slot_index === slotIndex);
  if (!cellHasItem) {
    contextMenu.value = null;
    return;
  }

  drag.value = null;
  hover.value = null;
  book.selectedIndex = slotIndex;
  contextMenu.value = { book: bookKey, slot: slotIndex, x: event.clientX, y: event.clientY };
}

function contextStack() {
  const c = contextMenu.value;
  if (!c) return { book: null, items: [] };
  const book = bookByKey(c.book);
  return { book, items: book.items.filter((i) => i.slot_index === c.slot) };
}

function onContextUse() {
  const { items } = contextStack();
  contextMenu.value = null;
  if (items.length === 0) return;
  const item = items[0];
  api.post('Feather:Inventory:UseItem', { itemId: item.id, itemName: item.name }).catch((e) => console.log(e.message));
}

// Drop/Give prompt for a quantity first when the compartment holds more
// than one unit -- a single item (or a non-stackable one, which can only
// ever hold one) skips the modal and just acts, per your call.
const quantityPrompt = ref(null); // { action: 'drop' | 'give', book, items, itemName, max } | null

function onContextGive() {
  const { items } = contextStack();
  contextMenu.value = null;
  if (items.length === 0) return;

  if (items.length > 1) {
    quantityPrompt.value = { action: 'give', book: null, items, itemName: items[0].display_name, max: items.length };
    return;
  }

  performGive(items);
}

function onContextDrop() {
  const { book, items } = contextStack();
  contextMenu.value = null;
  if (!book || items.length === 0) return;

  if (items.length > 1) {
    quantityPrompt.value = { action: 'drop', book, items, itemName: items[0].display_name, max: items.length };
    return;
  }

  performDrop(book, items);
}

function onQuantityConfirm(quantity) {
  const prompt = quantityPrompt.value;
  quantityPrompt.value = null;
  if (!prompt) return;

  const chosen = prompt.items.slice(0, quantity);
  if (prompt.action === 'drop') {
    performDrop(prompt.book, chosen);
  } else {
    performGive(chosen);
  }
}

function performDrop(book, items) {
  api
    .post('Feather:Inventory:DropItems', { items: items.map((i) => i.id) })
    .then(({ data }) => {
      if (data?.error) {
        console.log('Drop rejected: ' + (data.message || 'unknown error'));
        return;
      }
      if (data?.inv?.sourceItems) book.items = data.inv.sourceItems;
    })
    .catch((e) => console.log(e.message));
}

// Feather:Inventory:GiveItem only ever takes one item per call (it re-
// resolves "whoever's standing in front of you" fresh each time on the Lua
// side) -- giving several units of a stack is just that same call repeated
// in order, not a new server-side batch path.
async function performGive(items) {
  for (const item of items) {
    try {
      await api.post('Feather:Inventory:GiveItem', { item });
    } catch (e) {
      console.log(e.message);
      break;
    }
  }
}

const contextCanUse = computed(() => !!contextStack().items[0]?.usable);
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
        @cell-context-menu="(i, e) => onCellContextMenu('player', i, e)"
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
        @cell-context-menu="(i, e) => onCellContextMenu('other', i, e)"
      />
    </div>

    <div v-if="hasOther" class="ledger-hint">Drag an entry from one book to the other to move it &bull; ESC closes both</div>

    <ContextMenu
      v-if="contextMenu"
      :x="contextMenu.x"
      :y="contextMenu.y"
      :can-use="contextCanUse"
      @use="onContextUse"
      @give="onContextGive"
      @drop="onContextDrop"
      @close="contextMenu = null"
    />

    <ItemCountModal
      v-if="quantityPrompt"
      :item-name="quantityPrompt.itemName"
      :action-label="quantityPrompt.action === 'drop' ? 'Drop' : 'Give'"
      :max="quantityPrompt.max"
      @confirm="onQuantityConfirm"
      @cancel="quantityPrompt = null"
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

</style>
