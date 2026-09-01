<script setup>
import api from './api';
import { computed, nextTick, onMounted, onUnmounted, reactive, ref } from 'vue';
import '@/assets/tailwind.css';
import LedgerBook from '@/components/LedgerBook.vue';
import ContextMenu from '@/components/ContextMenu.vue';
import ItemCountModal from '@/components/ItemCountModal.vue';
import Hotbar from '@/components/Hotbar.vue';
import { t, setStrings, setConditionStages } from '@/i18n';

const visible = ref(false);
const previewMode = import.meta.env.DEV
  ? new URLSearchParams(window.location.search).get('preview')
  : null;
// Keep the ledger visible under Vite so its static layout can be developed
// and visually verified without a running RedM NUI message bridge. This is
// compile-time false in the production build.
const devmode = ref(import.meta.env.DEV && previewMode !== 'hotbar');

function makeBook(footerLabel) {
  return reactive({
    title: '',
    subtitle: '',
    footerLabel,
    capacity: 0,
    maxWeight: 0,
    inventoryId: null,
    ignoreLimits: 0,
    items: [],
    activeCategoryId: null,
    searchQuery: '',
    selectedIndex: -1,
  });
}

const player = makeBook('ui_carrying');
const other = makeBook('ui_stored');
const hasOther = computed(() => other.inventoryId !== null);
const hotbar = reactive({ enabled: false, visible: false, slots: 6, bindings: [], opacity: 90, modifier: 'SHIFT' });

const rawCategories = ref([]);
const categoryOptions = computed(() => [
  { id: null, label: t('ui_all') },
  ...rawCategories.value.map((c) => ({ id: c.id, label: String(c.name).toUpperCase() })),
]);

// Vite-only preview data: makes the complete NUI reviewable in a browser
// without RedM or a live server message bridge. import.meta.env.DEV is
// compile-time false in the packaged production build.
if (import.meta.env.DEV) {
  player.title = 'PERSONAL EFFECTS';
  player.subtitle = 'Arthur Morgan';
  player.capacity = 40;
  player.maxWeight = 125;
  player.items = [
    { id: 101, slot_index: 0, name: 'consumable_apple', display_name: 'Apple', description: 'A fresh apple.', usable: 1, weight: 0.25, category_id: 1 },
    { id: 102, slot_index: 0, name: 'consumable_apple', display_name: 'Apple', description: 'A fresh apple.', usable: 1, weight: 0.25, category_id: 1 },
    { id: 103, slot_index: 1, name: 'consumable_coffee', display_name: 'Coffee', description: 'Ground coffee for the trail.', usable: 1, weight: 1, category_id: 1 },
    { id: 104, slot_index: 7, name: 'medical_tonic', display_name: 'Health Tonic', description: 'Restores health.', usable: 1, weight: 1, category_id: 2 },
  ];
  rawCategories.value = [{ id: 1, name: 'provisions' }, { id: 2, name: 'medical' }];
  Object.assign(hotbar, {
    enabled: true,
    visible: true,
    slots: 6,
    bindings: [
      { slot: 1, itemName: 'consumable_apple', displayName: 'Apple', quantity: 2, available: true },
      { slot: 2, itemName: 'consumable_coffee', displayName: 'Coffee', quantity: 1, available: true },
      { slot: 3, itemName: 'medical_tonic', displayName: 'Health Tonic', quantity: 0, available: false },
    ],
  });
}

// Single global drag pointer shared across both books -- lets a drag that
// started in one book highlight valid drop targets in the other.
const drag = ref(null); // { book: 'player' | 'other', slot, itemId }
const hover = ref(null); // { book, slot }
const hotbarDragEligible = computed(() => {
  if (!drag.value || drag.value.book !== 'player') return false;
  return player.items.some((item) => item.slot_index === drag.value.slot && !!item.usable);
});

const contextMenu = ref(null); // { book, slot, x, y } | null
const mutationBusy = ref(false);
const mutationBusyLabel = ref('ui_working');

async function withMutationBusy(labelKey, action) {
  if (mutationBusy.value) return;
  const startedAt = performance.now();
  mutationBusyLabel.value = labelKey;
  mutationBusy.value = true;
  clearDrag();
  contextMenu.value = null;
  quantityPrompt.value = null;
  try {
    // Let Vue commit and the browser paint the shield before starting a NUI
    // request. Fast mutations (especially a one-item ground drop) could
    // previously finish in the same render turn, so the status never became
    // visible even though the operation did enter the busy state.
    await nextTick();
    await new Promise((resolve) => requestAnimationFrame(resolve));
    return await action();
  } finally {
    // Avoid a single-frame flash that is functionally present but impossible
    // for a player to read. Long-running mutations incur no extra delay.
    const remaining = 250 - (performance.now() - startedAt);
    if (remaining > 0) await new Promise((resolve) => setTimeout(resolve, remaining));
    mutationBusy.value = false;
  }
}

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
  if (data.type === 'mutationBusy') {
    mutationBusy.value = data.busy === true;
    if (data.labelKey) mutationBusyLabel.value = String(data.labelKey);
    return;
  }
  if (data.type === 'hotbar') {
    hotbar.enabled = data.enabled === true;
    hotbar.visible = data.visible === true;
    hotbar.slots = Number(data.slots) || 6;
    hotbar.bindings = Array.isArray(data.bindings) ? data.bindings : [];
    hotbar.opacity = Math.max(50, Math.min(100, Number(data.opacity) || 90));
    hotbar.modifier = String(data.modifier || 'SHIFT').toUpperCase();
    return;
  }
  if (data.type !== 'toggleInventory') return;

  visible.value = data.visible;
  rawCategories.value = data.categories || [];
  setStrings(data.strings);
  setConditionStages(data.conditionStages, data.conditionMax);

  player.title = t('ui_personal_effects');
  player.subtitle = data.player?.characterName || '';
  // Each book has its own capacity now -- fall back to the old global
  // maxSlots so a server that predates the per-book fields still renders.
  player.capacity = Number(data.playerMaxSlots) || Number(data.maxSlots) || 0;
  player.maxWeight = Number(data.playerMaxWeight) || Number(data.maxWeight) || 0;
  player.inventoryId = data.playerInventory;
  player.ignoreLimits = data.playerIgnoreLimits || 0;
  player.items = data.playerItems || [];
  player.activeCategoryId = null;
  player.searchQuery = '';
  player.selectedIndex = -1;

  if (data.otherItems != null) {
    other.title = String(data.otherName || t('ui_storage')).toUpperCase();
    other.subtitle = '';
    other.capacity = Number(data.otherMaxSlots) || Number(data.maxSlots) || 0;
    other.maxWeight = Number(data.otherMaxWeight) || Number(data.maxWeight) || 0;
    other.inventoryId = data.otherInventory;
    other.ignoreLimits = data.otherIgnoreLimits || 0;
    other.items = data.otherItems;
    other.activeCategoryId = null;
    other.searchQuery = '';
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
  if (event.code === 'Escape' && !mutationBusy.value) closeApp();
};

const closeApp = () => {
  if (mutationBusy.value) return;
  visible.value = false;
  drag.value = null;
  hover.value = null;
  contextMenu.value = null;
  quantityPrompt.value = null;
  api.post('Feather:Inventory:NuiCloseInventory', {}).catch((e) => console.log(e.message));
};

// --- Drag and drop -------------------------------------------------------

function onCellMouseDown(bookKey, slotIndex, event) {
  contextMenu.value = null;

  const book = bookByKey(bookKey);
  const stack = book.items.filter((i) => i.slot_index === slotIndex);
  if (stack.length === 0) return;

  book.selectedIndex = slotIndex;

  // Shift+click quick-transfers the whole compartment to the other book
  // instead of starting a drag -- the bulk-transfer half of README's
  // "shift+drag" item. Only meaningful when a second book is actually open;
  // otherwise fall through to a normal drag.
  if (event && event.shiftKey && hasOther.value) {
    quickTransfer(bookKey, stack);
    return;
  }

  drag.value = { book: bookKey, slot: slotIndex };
}

// Deliberately routed through UpdateInventory rather than MoveItem: this has
// no destination slot to name, and UpdateInventory -> MoveInventoryItems
// already assigns one server-side (join a matching under-full stack, else the
// first free compartment) with capacity, weight and blacklist all enforced on
// the way. Picking a slot client-side would duplicate that logic and race it.
// (§10.3 quick-loot) Server-side greedy move -- see the TakeAll RPC for why
// it isn't UpdateInventory with every id (that check is all-or-nothing, so a
// pile bigger than your remaining room would yield nothing at all).
async function onTakeAll() {
  if (!other.inventoryId || mutationBusy.value) return;
  await withMutationBusy('ui_taking_all', async () => {
   try {
    const { data } = await api.post('Feather:Inventory:TakeAll', {
      fromInventory: other.inventoryId,
    });
    if (data?.error) {
      console.log('Take all rejected: ' + (data.message || 'unknown error'));
      return;
    }
    if (data?.sourceItems) other.items = data.sourceItems;
    if (data?.targetItems) player.items = data.targetItems;
  } catch (e) {
    console.log(e.message);
    }
  });
}

async function quickTransfer(fromKey, stack) {
  const fromBook = bookByKey(fromKey);
  const toBook = fromKey === 'player' ? other : player;
  if (!fromBook.inventoryId || !toBook.inventoryId) return;

  try {
    const { data } = await api.post('Feather:Inventory:UpdateInventory', {
      sourceInventory: fromBook.inventoryId,
      targetInventory: toBook.inventoryId,
      items: stack.map((i) => i.id),
    });
    if (data?.error) {
      console.log('Transfer rejected: ' + (data.message || 'unknown error'));
      return;
    }
    if (data?.sourceItems) fromBook.items = data.sourceItems;
    if (data?.targetItems) toBook.items = data.targetItems;
  } catch (e) {
    console.log(e.message);
  }
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
  const originalFromItems = [...fromBook.items];
  const originalToItems = fromBook === toBook ? originalFromItems : [...toBook.items];
  const originalSlots = new Map(
    [...new Set([...originalFromItems, ...originalToItems])].map((item) => [item, item.slot_index]),
  );
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
    for (const [item, originalSlot] of originalSlots) item.slot_index = originalSlot;
    fromBook.items = [...originalFromItems];
    if (fromBook !== toBook) toBook.items = [...originalToItems];
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

  performUse(item);
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
  performUse(item);
}

async function performUse(item) {
  await withMutationBusy('ui_using_item', async () => {
    try {
      const { data } = await api.post('Feather:Inventory:UseItem', {
        itemId: item.id,
        itemName: item.name,
      });
      if (data?.error) console.log('Use rejected: ' + (data.message || 'unknown error'));
    } catch (e) {
      console.log(e.message);
    }
  });
}

// Drop/Give prompt for a quantity first when the compartment holds more
// than one unit -- a single item (or a non-stackable one, which can only
// ever hold one) skips the modal and just acts, per your call.
const quantityPrompt = ref(null); // { action: 'drop' | 'give', book, items, itemName, max } | null

function onContextGive(event) {
  const { book, items } = contextStack();
  contextMenu.value = null;
  if (items.length === 0) return;

  // Shift skips the quantity prompt and acts on the whole stack -- the
  // bulk-drop/give half of README's "shift+drag" item.
  if (items.length > 1 && !(event && event.shiftKey)) {
    quantityPrompt.value = { action: 'give', book, items, itemName: items[0].display_name, max: items.length };
    return;
  }

  performGive(book, items);
}

function onContextDrop(event) {
  const { book, items } = contextStack();
  contextMenu.value = null;
  if (!book || items.length === 0) return;

  if (items.length > 1 && !(event && event.shiftKey)) {
    quantityPrompt.value = { action: 'drop', book, items, itemName: items[0].display_name, max: items.length };
    return;
  }

  performDrop(book, items);
}

// Split always prompts -- there's no sensible "just do it" default for how
// much to peel off. Capped at items.length - 1: moving the whole stack out
// would leave an empty compartment behind, which is a move, not a split
// (the server rejects it too, rather than trusting this cap).
function onContextSplit() {
  const { book, items } = contextStack();
  contextMenu.value = null;
  if (!book || items.length < 2) return;

  quantityPrompt.value = {
    action: 'split',
    book,
    items,
    itemName: items[0].display_name,
    max: items.length - 1,
  };
}

function onQuantityConfirm(quantity) {
  const prompt = quantityPrompt.value;
  quantityPrompt.value = null;
  if (!prompt) return;

  if (prompt.action === 'split') {
    // Split sends the source compartment's item id and a count, not a list
    // of ids -- the server re-reads the stack from the slot itself rather
    // than trusting which specific rows the client picked.
    performSplit(prompt.book, prompt.items[0], quantity);
    return;
  }

  const chosen = prompt.items.slice(0, quantity);
  if (prompt.action === 'drop') {
    performDrop(prompt.book, chosen);
  } else {
    performGive(prompt.book, chosen);
  }
}

function performSplit(book, item, quantity) {
  api
    .post('Feather:Inventory:SplitStack', { itemId: item.id, quantity })
    .then(({ data }) => {
      if (data?.error) {
        console.log('Split rejected: ' + (data.message || 'unknown error'));
        return;
      }
      if (data?.sourceItems) book.items = data.sourceItems;
    })
    .catch((e) => console.log(e.message));
}

async function performDrop(book, items) {
  await withMutationBusy('ui_dropping_items', async () => {
    try {
      const { data } = await api.post('Feather:Inventory:DropItems', { items: items.map((i) => i.id) });
      if (data?.error) {
        console.log('Drop rejected: ' + (data.message || 'unknown error'));
        return;
      }
      if (data?.inv?.sourceItems) book.items = data.inv.sourceItems;
    } catch (e) {
      console.log(e.message);
    }
  });
}

// Feather:Inventory:GiveItem only ever takes one item per call (it re-
// resolves "whoever's standing in front of you" fresh each time on the Lua
// side) -- giving several units of a stack is just that same call repeated
// in order, not a new server-side batch path.
//
// The response used to be checked for nothing but a network-level
// rejection -- a clean { error, message } response (no player in front of
// you, target too far, etc.) was silently ignored, so a failed give looked
// like nothing happened at all. Now surfaced the same way performDrop
// reports its rejections.
async function performGive(book, items) {
  for (const item of items) {
    try {
      const { data } = await api.post('Feather:Inventory:GiveItem', { item });
      if (data?.error) {
        console.log('Give rejected: ' + (data.message || 'unknown error'));
        break;
      }
      if (book && data?.sourceItems) book.items = data.sourceItems;
    } catch (e) {
      console.log(e.message);
      break;
    }
  }
}

const contextCanUse = computed(() => !!contextStack().items[0]?.usable);
async function setHotbarSlot(slot, item) {
  try {
    const { data } = await api.post('Feather:Inventory:Hotbar:Set', {
      slot,
      itemId: item.id,
    });
    if (data?.error) console.log('Hotbar assignment rejected: ' + (data.message || 'unknown error'));
  } catch (error) {
    console.log(error.message);
  }
}

function assignDraggedItemToHotbar(slot) {
  const currentDrag = drag.value;
  if (!currentDrag || currentDrag.book !== 'player') return clearDrag();
  const item = player.items.find((candidate) => candidate.slot_index === currentDrag.slot);
  clearDrag();
  if (!item || !item.usable) return;
  setHotbarSlot(slot, item);
}

async function clearHotbarSlot(slot) {
  try {
    const { data } = await api.post('Feather:Inventory:Hotbar:Set', { slot, itemId: null });
    if (data?.error) console.log('Hotbar clear rejected: ' + (data.message || 'unknown error'));
  } catch (error) {
    console.log(error.message);
  }
}
// Only offer Split where there's actually something to split -- a single
// unit has nothing to peel off.
const contextCanSplit = computed(() => contextStack().items.length > 1);

const QUANTITY_ACTION_KEYS = { drop: 'ui_drop', give: 'ui_give', split: 'ui_split' };
const quantityActionLabel = computed(() => {
  const key = QUANTITY_ACTION_KEYS[quantityPrompt.value?.action];
  return key ? t(key) : t('ui_confirm');
});
</script>

<template>
  <Hotbar
    v-if="hotbar.enabled && ((hotbar.visible && !visible && !devmode) || visible || devmode)"
    :slots="hotbar.slots"
    :bindings="hotbar.bindings"
    :assignment-mode="visible || devmode"
    :drag-active="hotbarDragEligible"
    :opacity="hotbar.opacity"
    :modifier="hotbar.modifier"
    @assign="assignDraggedItemToHotbar"
    @clear="clearHotbarSlot"
  />
  <div v-if="mutationBusy && !visible" class="ledger-busy-shield" aria-live="polite">
    <div class="ledger-busy-card">
      <span class="ledger-busy-spinner" aria-hidden="true"></span>
      <span>{{ t(mutationBusyLabel) }}</span>
    </div>
  </div>
  <div v-if="visible || devmode" class="ledger-overlay">
    <div class="ledger-vignette"></div>
    <div class="ledger-close" :class="{ disabled: mutationBusy }" @click="!mutationBusy && closeApp()">&times;</div>

    <div v-if="mutationBusy" class="ledger-busy-shield" aria-live="polite">
      <div class="ledger-busy-card">
        <span class="ledger-busy-spinner" aria-hidden="true"></span>
        <span>{{ t(mutationBusyLabel) }}</span>
      </div>
    </div>

    <div class="ledger-books" :class="{ paired: hasOther }">
      <LedgerBook
        title="PERSONAL EFFECTS"
        :subtitle="player.subtitle"
        footer-label="CARRYING"
        :capacity="player.capacity"
        :max-weight="player.maxWeight"
        :items="player.items"
        :categories="categoryOptions"
        v-model:active-category-id="player.activeCategoryId"
        v-model:search-query="player.searchQuery"
        v-model:selected-index="player.selectedIndex"
        paired
        :drag-slot="drag && drag.book === 'player' ? drag.slot : -1"
        :drag-armed="dragArmedFor('player')"
        :hover-slot="hover && hover.book === 'player' ? hover.slot : -1"
        @cell-mouse-down="(i, e) => onCellMouseDown('player', i, e)"
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
        :max-weight="other.maxWeight"
        :items="other.items"
        :categories="categoryOptions"
        v-model:active-category-id="other.activeCategoryId"
        v-model:search-query="other.searchQuery"
        v-model:selected-index="other.selectedIndex"
        paired
        :drag-slot="drag && drag.book === 'other' ? drag.slot : -1"
        :drag-armed="dragArmedFor('other')"
        :hover-slot="hover && hover.book === 'other' ? hover.slot : -1"
        @cell-mouse-down="(i, e) => onCellMouseDown('other', i, e)"
        @cell-mouse-enter="(i) => onCellMouseEnter('other', i)"
        @cell-mouse-up="(i) => onCellMouseUp('other', i)"
        @cell-dbl-click="(i) => onCellDblClick('other', i)"
        @cell-context-menu="(i, e) => onCellContextMenu('other', i, e)"
        :can-take-all="true"
        :take-all-busy="mutationBusy"
        @take-all="onTakeAll"
      />
    </div>

    <div v-if="hasOther" class="ledger-hint">{{ t('ui_paired_hint') }}</div>

    <ContextMenu
      v-if="contextMenu"
      :x="contextMenu.x"
      :y="contextMenu.y"
      :can-use="contextCanUse"
      :can-split="contextCanSplit"
      @use="onContextUse"
      @give="onContextGive"
      @drop="onContextDrop"
      @split="onContextSplit"
      @close="contextMenu = null"
    />

    <ItemCountModal
      v-if="quantityPrompt"
      :item-name="quantityPrompt.itemName"
      :action-label="quantityActionLabel"
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
  background: transparent;
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
  --ledger-scale: min(calc(100vw / 1920px), calc(100vh / 1080px));
}

.ledger-vignette {
  position: absolute;
  inset: 0;
  background: radial-gradient(ellipse at center, rgba(0, 0, 0, 0) 26%, rgba(0, 0, 0, 0.38) 100%);
  pointer-events: none;
}

.ledger-busy-shield {
  position: fixed;
  inset: 0;
  z-index: 10000;
  display: flex;
  align-items: center;
  justify-content: center;
  cursor: wait;
  background: rgba(18, 14, 10, 0.2);
}

.ledger-busy-card {
  display: flex;
  align-items: center;
  gap: 14px;
  padding: 14px 22px;
  color: #2b2118;
  background: #d8c8a5;
  border: 2px solid #5c4933;
  box-shadow: 0 8px 30px rgba(0, 0, 0, 0.55);
  font-family: 'Playfair Display', serif;
  font-size: 18px;
  font-weight: 800;
  text-transform: uppercase;
  letter-spacing: 0.08em;
}

.ledger-busy-spinner {
  width: 18px;
  height: 18px;
  border: 2px solid rgba(43, 33, 24, 0.3);
  border-top-color: #2b2118;
  border-radius: 50%;
  animation: ledger-busy-spin 0.8s linear infinite;
}

@keyframes ledger-busy-spin {
  to { transform: rotate(360deg); }
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

.ledger-close.disabled {
  cursor: wait;
  opacity: 0.45;
}

</style>
