<script setup>
import { computed, ref } from 'vue';
import { t, conditionStage, conditionMax } from '@/i18n';

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
  searchQuery: { type: String, default: '' },
  selectedIndex: { type: Number, default: -1 },
  paired: { type: Boolean, default: false },
  // Drag/hover state for THIS book specifically, already resolved by the
  // parent (which owns the single global drag pointer across both books).
  dragSlot: { type: Number, default: -1 },
  dragArmed: { type: Boolean, default: false }, // a drag from a book paired with this one is in progress
  hoverSlot: { type: Number, default: -1 },
  // (§10.3 quick-loot) Only the paired "other" book offers Take All --
  // there is nowhere to take your own inventory to.
  canTakeAll: { type: Boolean, default: false },
  takeAllBusy: { type: Boolean, default: false },
});

const emit = defineEmits([
  'update:activeCategoryId',
  'update:searchQuery',
  'update:selectedIndex',
  'cellMouseDown',
  'cellMouseEnter',
  'cellMouseUp',
  'cellDblClick',
  'cellContextMenu',
  'takeAll',
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

const categoryOpen = ref(false);
const activeCategory = computed(() =>
  props.categories.find((category) => category.id === props.activeCategoryId) || props.categories[0],
);

function selectCategory(id) {
  emit('update:activeCategoryId', id);
  categoryOpen.value = false;
}

function closeCategoryOnBlur(event) {
  if (!event.currentTarget.contains(event.relatedTarget)) categoryOpen.value = false;
}

const cells = computed(() => {
  const query = props.searchQuery.trim().toLocaleLowerCase();
  return slots.value.map((stack, index) => {
    const repItem = stack ? stack[0] : null;
    const matchesCategory = repItem &&
      (props.activeCategoryId == null || repItem.category_id === props.activeCategoryId);
    const searchableText = repItem
      ? `${repItem.display_name || ''} ${repItem.name || ''} ${repItem.description || ''}`.toLocaleLowerCase()
      : '';
    const matchesSearch = !query || searchableText.includes(query);
    const visible = repItem && matchesCategory && matchesSearch;
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
    return { label: '—', desc: t('ui_no_entry'), weight: '—', qtyPlain: '—', img: null, condition: null };
  }
  // (§10.3) Condition rides along in metadata, which the server already
  // sends with every row -- no extra payload field needed. Absent metadata
  // means this instance has no condition recorded, which is not the same as
  // zero, so it renders nothing rather than "Ruined".
  const raw = cell.repItem.metadata && cell.repItem.metadata.condition;
  const value = Number(raw);
  const hasCondition = raw !== undefined && raw !== null && Number.isFinite(value);
  const stage = hasCondition ? conditionStage(value) : null;

  return {
    label: cell.repItem.display_name,
    desc: cell.repItem.description,
    // 2dp: weights can be fractional now, and toFixed(1) would render a
    // 0.25 lb item as "0.2".
    weight: (Number(cell.repItem.weight) * cell.qty).toFixed(2) + ' lb.',
    qtyPlain: String(cell.qty),
    img: iconSrc(cell.repItem.name),
    condition: hasCondition
      ? (stage ? `${stage} (${value}/${conditionMax()})` : `${value}/${conditionMax()}`)
      : null,
  };
});

// A limit of 0 means unlimited (ground piles register that way) -- show the
// weight carried but no "/ limit", rather than rendering "/ 0 lb.", which
// reads as a container that can hold nothing.
const hasWeightLimit = computed(() => Number(props.maxWeight) > 0);

const carrying = computed(() => {
  const lb = props.items.reduce((total, item) => total + (Number(item.weight) || 0), 0);
  return lb.toFixed(2);
});

function iconSrc(name) {
  // Relative, not root-absolute: the release action flattens Vite's dist
  // contents into ui/, so images/ sits next to ui/index.html. A
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

// (§10.3) Per-cell wear indicator. Returns 0..1, or null when this instance
// has no condition recorded -- which is not the same as zero, so those cells
// render no bar at all rather than an empty one reading as "ruined".
function cellCondition(cell) {
  if (!cell.repItem) return null;
  const raw = cell.repItem.metadata && cell.repItem.metadata.condition;
  if (raw === undefined || raw === null) return null;
  const value = Number(raw);
  if (!Number.isFinite(value)) return null;
  const max = conditionMax() || 100;
  return Math.max(0, Math.min(value / max, 1));
}

function cellBg(cell) {
  if (cell.index === props.hoverSlot && props.dragArmed) return 'rgba(90,68,34,.24)';
  if (cell.index === props.selectedIndex && cell.repItem) return 'rgba(90,68,34,.13)';
  if (cell.index === props.dragSlot) return 'rgba(90,68,34,.13)';
  if (cell.hiddenByFilter) return 'rgba(120,96,56,.05)';
  return 'transparent';
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

      <div class="ledger-filters">
        <div class="ledger-category" tabindex="-1" @focusout="closeCategoryOnBlur">
          <button
            type="button"
            class="ledger-category-trigger"
            :aria-expanded="categoryOpen"
            @click="categoryOpen = !categoryOpen"
          >
            <span>{{ activeCategory?.label || t('ui_all') }}</span>
            <span class="ledger-category-caret" aria-hidden="true">&#9662;</span>
          </button>
          <div v-if="categoryOpen" class="ledger-category-menu">
            <button
              v-for="cat in categories"
              :key="cat.label"
              type="button"
              class="ledger-category-option"
              :class="{ active: cat.id === activeCategoryId }"
              @click="selectCategory(cat.id)"
            >
              {{ cat.label }}
            </button>
          </div>
        </div>
        <input
          class="ledger-search"
          type="text"
          :value="searchQuery"
          :placeholder="t('ui_search')"
          :aria-label="t('ui_search')"
          autocomplete="off"
          @input="emit('update:searchQuery', $event.target.value)"
        />
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
            @mousedown.left.prevent="(event) => emit('cellMouseDown', cell.index, event)"
            @mouseup.left="emit('cellMouseUp', cell.index)"
            @mouseenter="emit('cellMouseEnter', cell.index)"
            @dblclick="emit('cellDblClick', cell.index)"
            @contextmenu.prevent="(event) => emit('cellContextMenu', cell.index, event)"
          >
            <div class="ledger-cell-icon">
              <img
                v-if="cell.repItem"
                :key="cell.repItem.name"
                :src="iconSrc(cell.repItem.name)"
                class="ink"
                draggable="false"
                @error="onIconError"
              />
            </div>
            <div v-if="cell.repItem" class="ledger-cell-qty">&times;{{ cell.qty }}</div>
            <div v-if="cellCondition(cell) !== null" class="ledger-cell-wear">
              <div class="ledger-cell-wear-fill" :style="{ width: (cellCondition(cell) * 100) + '%' }"></div>
            </div>
            <div v-if="cell.index === selectedIndex && cell.repItem" class="ledger-pointer"></div>
          </div>
        </div>
      </div>

      <div class="ledger-detail">
        <div class="ledger-detail-icon">
          <img v-if="detail.img" :key="detail.img" :src="detail.img" class="ink" draggable="false" @error="onIconError" />
        </div>
        <div class="ledger-detail-body">
          <div class="ledger-detail-name">{{ detail.label }}</div>
          <div class="ledger-detail-desc">{{ detail.desc }}</div>
          <div class="ledger-detail-footer">
            <span>{{ t('ui_quantity') }} &mdash; {{ detail.qtyPlain }}</span>
            <span>{{ t('ui_weight') }} &mdash; {{ detail.weight }}</span>
            <span v-if="detail.condition">{{ t('ui_condition') }} &mdash; {{ detail.condition }}</span>
          </div>
        </div>
      </div>

      <button
        v-if="canTakeAll"
        type="button"
        class="ledger-take-all"
        :class="{ busy: takeAllBusy }"
        :disabled="takeAllBusy"
        @click="emit('takeAll')"
      >{{ takeAllBusy ? t('ui_taking_all') : t('ui_take_all') }}</button>

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

.ledger-filters {
  margin-top: 9px;
  display: grid;
  grid-template-columns: minmax(0, 1fr) minmax(0, 1fr);
  gap: 12px;
  font-family: 'Playfair Display', serif;
  font-weight: 500;
  letter-spacing: 0.04em;
}

.ledger-category {
  position: relative;
  min-width: 0;
}

.ledger-category-trigger,
.ledger-search,
.ledger-category-option {
  color: #2b2013;
  font: inherit;
}

.ledger-category-trigger,
.ledger-search {
  width: 100%;
  height: 31px;
  box-sizing: border-box;
  border: 0;
  border-bottom: 1px solid rgba(43, 32, 19, 0.55);
  background: rgba(120, 96, 56, 0.04);
}

.ledger-category-trigger {
  padding: 3px 7px;
  display: flex;
  align-items: center;
  justify-content: space-between;
  cursor: pointer;
  text-align: left;
  text-transform: uppercase;
}

.ledger-category-caret {
  margin-left: 8px;
  font-size: 12px;
}

.ledger-category-menu {
  position: absolute;
  z-index: 20;
  top: calc(100% + 2px);
  left: 0;
  right: 0;
  padding: 4px;
  border: 1px solid rgba(43, 32, 19, 0.55);
  background: #d7c39a;
  box-shadow: 0 8px 16px rgba(43, 32, 19, 0.28);
}

.ledger-category-option {
  display: block;
  width: 100%;
  padding: 5px 7px;
  border: 0;
  background: transparent;
  cursor: pointer;
  text-align: left;
  text-transform: uppercase;
}

.ledger-category-option:hover,
.ledger-category-option.active {
  background: rgba(90, 68, 34, 0.14);
}

.ledger-category-option.active {
  font-weight: 700;
}

.ledger-search {
  padding: 3px 7px;
  outline: none;
}

.ledger-search::placeholder {
  color: rgba(43, 32, 19, 0.56);
  text-transform: uppercase;
}

.ledger-search:focus,
.ledger-category-trigger:focus-visible {
  background: rgba(90, 68, 34, 0.1);
  outline: 1px solid rgba(43, 32, 19, 0.38);
}

.paired .ledger-filters {
  gap: 10px;
  font-size: 12px;
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

/* Wear bar: a thin ink rule along the bottom of the compartment. Chosen over
   a pristine/worn/damaged glyph because the ledger is engraving-only -- a
   status icon would read as a second item in the cell. Length carries the
   value; no colour, since colour is not part of this design's vocabulary. */
/* Sits between the detail box and the carrying line, outside the scrolling
   viewport, so it never moves with the compartments. */
.ledger-take-all {
  display: block;
  width: 100%;
  padding: 0;
  border: 0;
  background: transparent;
  margin-top: 6px;
  text-align: center;
  font-family: 'Playfair Display', serif;
  font-weight: 500;
  font-size: 12px;
  letter-spacing: 0.08em;
  text-transform: uppercase;
  color: #5c4a30;
  text-decoration: underline;
  cursor: pointer;
  user-select: none;
}

.ledger-take-all:hover {
  color: #2b2013;
}

.ledger-take-all:disabled,
.ledger-take-all.busy {
  color: #786b58;
  cursor: wait;
  text-decoration: none;
}

.ledger-cell-wear {
  position: absolute;
  left: 12%;
  right: 12%;
  bottom: 5px;
  height: 2px;
  background: rgba(43, 32, 19, 0.16);
}

.ledger-cell-wear-fill {
  height: 100%;
  background: rgba(43, 32, 19, 0.65);
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
.ledger-category-trigger,
.ledger-category-option,
.ledger-search {
  text-shadow: none;
}

.ink {
  filter: invert(1) sepia(0.55) saturate(0.6) contrast(1.25) brightness(0.62);
  -webkit-user-drag: none;
  user-drag: none;
}
</style>
