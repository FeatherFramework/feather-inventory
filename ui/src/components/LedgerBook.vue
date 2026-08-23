<script setup>
import { computed } from 'vue';
import { t } from '@/i18n';

// One "1899 personal effects ledger" book -- either the player's own
// inventory or the paired container/ground/robbery-target book. Fully
// controlled: all state (selection, active category, drag/hover) lives in
// App.vue so cross-book drag and close-resets-both-books are trivial to
// coordinate from one place.
const props = defineProps({
  title: { type: String, required: true },
  subtitle: { type: String, required: true },
  footerLabel: { type: String, required: true }, // locale KEY: ui_carrying | ui_stored
  capacity: { type: Number, required: true }, // compartments
  maxWeight: { type: Number, default: 0 }, // weight limit -- NOT capacity
  items: { type: Array, required: true }, // flat rows, each with slot_index
  categories: { type: Array, required: true }, // [{ id: null, label: <localized ALL> }, { id, label }, ...]
  activeCategoryId: { default: null },
  selectedIndex: { type: Number, default: -1 },
  paired: { type: Boolean, default: false },
  // Drag/hover state for THIS book specifically, already resolved by the
  // parent (which owns the single global drag pointer across both books).
  dragSlot: { type: Number, default: -1 },
  dragArmed: { type: Boolean, default: false }, // a drag from a book paired with this one is in progress
  hoverSlot: { type: Number, default: -1 },
});

const emit = defineEmits([
  'update:activeCategoryId',
  'update:selectedIndex',
  'cellMouseDown',
  'cellMouseEnter',
  'cellMouseUp',
  'cellDblClick',
  'cellContextMenu',
]);

// Every compartment sharing a slot_index stacks together (up to
// max_stack_size, enforced server-side) -- group the flat row list into one
// cell per occupied slot_index, `null` for genuinely empty compartments.
const slots = computed(() => {
  const grouped = new Array(props.capacity).fill(null);
  for (const item of props.items) {
    const idx = item.slot_index;
    if (idx == null || idx < 0 || idx >= props.capacity) continue;
    if (!grouped[idx]) grouped[idx] = [];
    grouped[idx].push(item);
  }
  return grouped;
});

const cells = computed(() => {
  return slots.value.map((stack, index) => {
    const repItem = stack ? stack[0] : null;
    const visible = repItem && (props.activeCategoryId == null || repItem.category_id === props.activeCategoryId);
    return {
      index,
      stack,
      repItem: visible ? repItem : null,
      qty: stack ? stack.length : 0,
      hiddenByFilter: !!(repItem && !visible),
    };
  });
});

// Deliberately does NOT fall back to the first occupied compartment when
// nothing (valid) is selected -- the design brief calls for that, but it
// reads as "an item picked itself" before you've clicked anything, or after
// the selected one gets consumed/moved away. A blank placeholder is less
// confusing than an item appearing to select itself.
const selectedCell = computed(() => {
  const cell = cells.value[props.selectedIndex];
  return cell && cell.repItem ? cell : null;
});

const detail = computed(() => {
  const cell = selectedCell.value;
  if (!cell || !cell.repItem) {
    return { label: '—', desc: t('ui_no_entry'), weight: '—', qtyPlain: '—', img: null };
  }
  return {
    label: cell.repItem.display_name,
    desc: cell.repItem.description,
    weight: (Number(cell.repItem.weight) * cell.qty).toFixed(1) + ' lb.',
    qtyPlain: String(cell.qty),
    img: iconSrc(cell.repItem.name),
  };
});

// A limit of 0 means unlimited (ground piles register that way) -- show the
// weight carried but no "/ limit", rather than rendering "/ 0 lb.", which
// reads as a container that can hold nothing.
const hasWeightLimit = computed(() => Number(props.maxWeight) > 0);

const carrying = computed(() => {
  const lb = props.items.reduce((total, item) => total + (Number(item.weight) || 0), 0);
  return lb.toFixed(1);
});

function iconSrc(name) {
  // Relative, not root-absolute: the release layout flattens the build so
  // images/ sits next to index.html inside ui/, not at the resource root
  // (see fxmanifest.lua's files{} -- "ui/index.html", "ui/images/*.*"). A
  // leading "/" resolves against the resource root under nui:// and misses
  // entirely; this must resolve against index.html's own location instead.
  return `images/items/${name}.png`;
}

function onIconError(event) {
  // A handful of seeded items have no sprite in public/images/items/ --
  // degrade to no icon rather than a broken-image box, per the design's
  // "engraving only" minimalism.
  event.target.style.display = 'none';
}

function cellBg(cell) {
  if (cell.index === props.hoverSlot && props.dragArmed) return 'rgba(90,68,34,.24)';
  if (cell.index === props.selectedIndex && cell.repItem) return 'rgba(90,68,34,.13)';
  if (cell.index === props.dragSlot) return 'rgba(90,68,34,.13)';
  if (cell.hiddenByFilter) return 'rgba(120,96,56,.05)';
  return 'transparent';
}

function tabLabelSize(count) {
  if (count >= 9) return '11px';
  if (count >= 7) return '12px';
  return '13px';
}
</script>

<template>
  <div class="ledger-book" :class="{ paired }">
    <div class="ledger-page">
      <div class="ledger-header">
        <img src="@/assets/ledger/rule-arrow-left.png" class="rule-arrow" />
        <div class="ledger-title">{{ title }}</div>
        <img src="@/assets/ledger/rule-arrow-right.png" class="rule-arrow" />
      </div>
      <div class="ledger-subtitle">{{ subtitle }}</div>

      <div class="ledger-rule"></div>

      <div class="ledger-tabs" :style="{ fontSize: tabLabelSize(categories.length) }">
        <div
          v-for="cat in categories"
          :key="cat.label"
          class="ledger-tab"
          @click="emit('update:activeCategoryId', cat.id)"
        >
          <div :class="{ active: cat.id === activeCategoryId }">{{ cat.label }}</div>
          <img
            v-if="cat.id === activeCategoryId"
            src="@/assets/ledger/tab-marker.png"
            class="tab-marker"
          />
        </div>
      </div>

      <div class="ledger-rule"></div>

      <div class="ledger-grid-viewport">
        <div class="ledger-grid">
          <div
            v-for="cell in cells"
            :key="cell.index"
            class="ledger-cell"
            :style="{ background: cellBg(cell) }"
            :class="{ selected: cell.index === selectedIndex && cell.repItem }"
            @mousedown.left.prevent="emit('cellMouseDown', cell.index)"
            @mouseup.left="emit('cellMouseUp', cell.index)"
            @mouseenter="emit('cellMouseEnter', cell.index)"
            @dblclick="emit('cellDblClick', cell.index)"
            @contextmenu.prevent="(event) => emit('cellContextMenu', cell.index, event)"
          >
            <div class="ledger-cell-icon">
              <img
                v-if="cell.repItem"
                :src="iconSrc(cell.repItem.name)"
                class="ink"
                draggable="false"
                @error="onIconError"
              />
            </div>
            <div v-if="cell.repItem" class="ledger-cell-qty">&times;{{ cell.qty }}</div>
            <div v-if="cell.index === selectedIndex && cell.repItem" class="ledger-pointer"></div>
          </div>
        </div>
      </div>

      <div class="ledger-detail">
        <div class="ledger-detail-icon">
          <img v-if="detail.img" :src="detail.img" class="ink" draggable="false" @error="onIconError" />
        </div>
        <div class="ledger-detail-body">
          <div class="ledger-detail-name">{{ detail.label }}</div>
          <div class="ledger-detail-desc">{{ detail.desc }}</div>
          <div class="ledger-detail-footer">
            <span>{{ t('ui_quantity') }} &mdash; {{ detail.qtyPlain }}</span>
            <span>{{ t('ui_weight') }} &mdash; {{ detail.weight }}</span>
          </div>
        </div>
      </div>

      <div class="ledger-carrying">
        <img src="@/assets/ledger/carry-arrow-left.png" class="carry-arrow" />
        <div class="ledger-carrying-text">{{ t(footerLabel) }}&nbsp;&nbsp;{{ carrying }}<span v-if="hasWeightLimit">&#8195;/&#8195;{{ maxWeight }}</span> lb.</div>
        <img src="@/assets/ledger/carry-arrow-right.png" class="carry-arrow" />
      </div>
    </div>
  </div>
</template>

<style scoped>
/* Sizes below are the board-5b (single-book) values from the design
   handoff's README; .paired overrides scale everything down to board-4b's
   two-books-open values. */
.ledger-book {
  position: relative;
  width: 574px;
  height: 983px;
  background-image: url('@/assets/ledger/folio-page.png');
  background-size: 100% 100%;
  filter: drop-shadow(0 34px 60px rgba(0, 0, 0, 0.7));
  /* The mousedown-driven drag here is custom, not native HTML5 DnD --
     without this, the browser's own text-selection drag and (especially)
     its default image-drag-ghost behavior on <img> elements fight with it,
     which is what caused drags to intermittently "stick" until an
     unrelated click reset the browser's own gesture state. */
  user-select: none;
  -webkit-user-select: none;
}

.ledger-book.paired {
  width: 528px;
  height: 905px;
  filter: drop-shadow(0 30px 56px rgba(0, 0, 0, 0.7));
}

.ledger-page {
  position: absolute;
  left: 11.93%;
  top: 5.31%;
  right: 6.53%;
  bottom: 5.64%;
  padding: 16px 18px 12px;
  box-sizing: border-box;
  display: flex;
  flex-direction: column;
  color: #2b2013;
  font-family: 'Old Standard TT', serif;
}

.paired .ledger-page {
  padding: 14px 16px 10px;
}

.ledger-header {
  display: flex;
  align-items: center;
  justify-content: center;
  gap: 14px;
}

.paired .ledger-header {
  gap: 12px;
}

.rule-arrow {
  height: 11px;
}

.paired .rule-arrow {
  height: 10px;
}

.ledger-title {
  font-family: 'Playfair Display', serif;
  font-weight: 900;
  font-size: 28px;
  letter-spacing: 0.05em;
  line-height: 1;
  white-space: nowrap;
  flex: none;
}

.paired .ledger-title {
  font-size: 24px;
}

.ledger-subtitle {
  margin-top: 8px;
  text-align: center;
  font-size: 17px;
  letter-spacing: 0.02em;
}

.paired .ledger-subtitle {
  margin-top: 6px;
  font-size: 15px;
}

.ledger-rule {
  margin-top: 12px;
  height: 1px;
  background: rgba(43, 32, 19, 0.55);
}

.ledger-tabs {
  margin-top: 9px;
  display: flex;
  justify-content: space-between;
  align-items: flex-start;
  flex-wrap: wrap;
  row-gap: 4px;
  font-family: 'Playfair Display', serif;
  font-weight: 500;
  letter-spacing: 0.07em;
}

.paired .ledger-tabs {
  font-size: 12px;
  letter-spacing: 0.06em;
}

.ledger-tab {
  position: relative;
  padding: 0 3px;
  cursor: pointer;
  text-align: center;
}

.ledger-tab div {
  color: #5c4a30;
}

.ledger-tab div.active {
  color: #2b2013;
}

.tab-marker {
  display: block;
  width: 62px;
  margin: 3px auto 0;
}

.paired .tab-marker {
  width: 54px;
}

/* (§10.4 scrollable grid) The book art is a fixed-size asset calibrated for
   one page of exactly 5x5 compartments, and the chrome around it (header,
   tabs, detail box, carrying line) is positioned against that. So the grid
   REGION stays pinned to exactly one page's height no matter what the
   inventory's capacity is -- only its contents scroll. A 60-slot wagon
   scrolls; it does not stretch the page and push the detail box out of the
   layout, which is what an auto-sized grid would do.

   Capacity below one page (a small pouch) deliberately leaves the remaining
   page area blank rather than shrinking the region, for the same reason:
   the art underneath doesn't resize. */
.ledger-grid-viewport {
  margin-top: 10px;
  height: 475px; /* 5 rows x 95px */
  overflow-y: auto;
  overflow-x: hidden;
  /* Thin ink-on-parchment scrollbar -- the default chrome one reads as a
     browser widget sitting on top of a 1899 ledger. */
  scrollbar-width: thin;
  scrollbar-color: rgba(43, 32, 19, 0.45) transparent;
}

.paired .ledger-grid-viewport {
  height: 430px; /* 5 rows x 86px */
}

.ledger-grid-viewport::-webkit-scrollbar {
  width: 6px;
}

.ledger-grid-viewport::-webkit-scrollbar-track {
  background: transparent;
}

.ledger-grid-viewport::-webkit-scrollbar-thumb {
  background: rgba(43, 32, 19, 0.4);
  border-radius: 3px;
}

.ledger-grid-viewport::-webkit-scrollbar-thumb:hover {
  background: rgba(43, 32, 19, 0.65);
}

.ledger-grid {
  display: grid;
  grid-template-columns: repeat(5, 1fr);
  /* auto-rows, not a pinned row count -- rows beyond the first page are
     reachable by scrolling the viewport above rather than being clipped. */
  grid-auto-rows: 95px;
  gap: 0;
}

.paired .ledger-grid {
  grid-auto-rows: 86px;
}

.ledger-cell {
  position: relative;
  cursor: grab;
  display: flex;
  flex-direction: column;
  align-items: center;
  justify-content: center;
  box-sizing: border-box;
  border: 1px solid rgba(43, 32, 19, 0.3);
}

.ledger-cell.selected {
  box-shadow: inset 0 0 0 2px #2b2013;
}

.ledger-cell-icon {
  height: 68px;
  display: flex;
  align-items: center;
  justify-content: center;
}

.paired .ledger-cell-icon {
  height: 42px;
}

.ledger-cell-icon img,
.ledger-detail-icon img {
  max-width: 64px;
  max-height: 64px;
  object-fit: contain;
  pointer-events: none;
}

.paired .ledger-cell-icon img {
  max-width: 38px;
  max-height: 38px;
}

.ledger-cell-qty {
  position: absolute;
  right: 6px;
  bottom: 4px;
  font-size: 12px;
  color: #4a3a24;
}

.paired .ledger-cell-qty {
  font-size: 10px;
}

.ledger-pointer {
  position: absolute;
  right: -8px;
  top: 50%;
  transform: translateY(-50%);
  width: 0;
  height: 0;
  border-top: 7px solid transparent;
  border-bottom: 7px solid transparent;
  border-left: 8px solid #2b2013;
  pointer-events: none;
}

.ledger-detail {
  margin-top: 14px;
  flex: 1;
  min-height: 0;
  border: 1px solid rgba(43, 32, 19, 0.45);
  padding: 14px 16px 12px;
  display: flex;
  gap: 18px;
  align-items: stretch;
}

.paired .ledger-detail {
  margin-top: 12px;
  padding: 12px 14px 10px;
  gap: 14px;
}

.ledger-detail-icon {
  width: 104px;
  flex: none;
  display: flex;
  align-items: center;
  justify-content: center;
  border-right: 1px solid rgba(43, 32, 19, 0.25);
}

.paired .ledger-detail-icon {
  width: 86px;
}

.ledger-detail-icon img {
  max-width: 92px;
  max-height: 92px;
}

.paired .ledger-detail-icon img {
  max-width: 76px;
  max-height: 76px;
}

.ledger-detail-body {
  flex: 1;
  display: flex;
  flex-direction: column;
}

.ledger-detail-name {
  font-family: 'Playfair Display', serif;
  font-weight: 700;
  font-size: 22px;
  letter-spacing: 0.03em;
}

.paired .ledger-detail-name {
  font-size: 19px;
}

.ledger-detail-desc {
  margin-top: 7px;
  font-size: 15px;
  line-height: 1.45;
}

.paired .ledger-detail-desc {
  margin-top: 5px;
  font-size: 14px;
  line-height: 1.4;
}

.ledger-detail-footer {
  margin-top: auto;
  display: flex;
  justify-content: space-between;
  font-size: 14px;
}

.paired .ledger-detail-footer {
  font-size: 13px;
}

.ledger-carrying {
  margin-top: auto;
  padding-top: 10px;
  display: flex;
  align-items: center;
  justify-content: center;
  gap: 12px;
}

.paired .ledger-carrying {
  padding-top: 8px;
  gap: 11px;
}

.carry-arrow {
  height: 7px;
}

.ledger-carrying-text {
  font-family: 'Playfair Display', serif;
  font-weight: 500;
  font-size: 15px;
  letter-spacing: 0.09em;
}

.paired .ledger-carrying-text {
  font-size: 14px;
}

/* Text-shadow/ink-filter/pointer-events blanket rules */
.ledger-header,
.ledger-title,
.ledger-cell-qty,
.ledger-carrying-text,
.ledger-tab {
  text-shadow: none;
}

.ink {
  filter: invert(1) sepia(0.55) saturate(0.6) contrast(1.25) brightness(0.62);
  -webkit-user-drag: none;
  user-drag: none;
}
</style>
