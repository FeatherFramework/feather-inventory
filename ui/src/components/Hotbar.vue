<script setup>
const props = defineProps({
  slots: { type: Number, default: 6 },
  bindings: { type: Array, default: () => [] },
  assignmentMode: { type: Boolean, default: false },
  dragActive: { type: Boolean, default: false },
  opacity: { type: Number, default: 90 },
  modifier: { type: String, default: "SHIFT" },
});

const emit = defineEmits(["assign", "clear"]);

function bindingFor(slot) {
  return (
    props.bindings.find((binding) => Number(binding.slot) === slot) || null
  );
}

function iconSrc(name) {
  return `images/items/${name}.png`;
}

function onIconError(event) {
  event.target.style.display = "none";
}
</script>

<template>
  <div
    class="hotbar"
    :class="{ 'assignment-mode': assignmentMode, 'drag-active': dragActive }"
    :style="{
      '--hotbar-content-opacity': assignmentMode
        ? 1
        : Math.max(0.5, Math.min(1, opacity / 100)),
    }"
    aria-label="Inventory hotbar"
  >
    <div v-if="assignmentMode" class="hotbar-assignment-hint">
      {{
        dragActive ? "DROP ON A QUICK SLOT" : "DRAG A USABLE ITEM TO THE HOTBAR"
      }}
    </div>
    <div v-else class="hotbar-use-hint">HOLD {{ modifier }} + Number</div>
    <div
      v-for="slot in slots"
      :key="slot"
      class="hotbar-slot"
      :class="{
        unavailable: bindingFor(slot) && !bindingFor(slot).available,
        'drop-ready': assignmentMode && dragActive,
      }"
      :title="
        assignmentMode
          ? bindingFor(slot)
            ? 'Drop to replace; right-click to clear'
            : 'Drop usable item here'
          : ''
      "
      @mouseup.stop="assignmentMode && emit('assign', slot)"
      @contextmenu.prevent.stop="
        assignmentMode && bindingFor(slot) && emit('clear', slot)
      "
    >
      <div class="hotbar-key">{{ slot }}</div>
      <img
        v-if="bindingFor(slot)"
        :src="iconSrc(bindingFor(slot).itemName)"
        :alt="bindingFor(slot).displayName"
        @error="onIconError"
      />
      <div v-if="bindingFor(slot)?.quantity > 1" class="hotbar-qty">
        &times;{{ bindingFor(slot).quantity }}
      </div>
    </div>
  </div>
</template>

<style scoped>
.hotbar {
  position: fixed;
  z-index: 40;
  left: 50%;
  bottom: 34px;
  transform: translateX(-50%);
  display: flex;
  gap: 7px;
  pointer-events: none;
  user-select: none;
  font-family: "Old Standard TT", serif;
}

.hotbar.assignment-mode {
  z-index: 80;
  pointer-events: auto;
}

.hotbar-assignment-hint {
  position: absolute;
  left: 50%;
  bottom: calc(100% + 10px);
  transform: translateX(-50%);
  width: max-content;
  padding: 5px 12px 4px;
  border: 1px solid rgba(43, 32, 19, 0.75);
  background: rgba(229, 211, 170, 0.96);
  box-shadow: 0 4px 12px rgba(0, 0, 0, 0.5);
  color: #382815;
  font-family: "Playfair Display", serif;
  font-size: 11px;
  font-weight: 700;
  letter-spacing: 0.08em;
  text-align: center;
  pointer-events: none;
}

.hotbar-use-hint {
  position: absolute;
  left: 50%;
  top: calc(100% + 6px);
  transform: translateX(-50%);
  width: max-content;
  color: rgba(242, 225, 185, 0.96);
  font-family: "Playfair Display", serif;
  font-size: 10px;
  font-weight: 700;
  letter-spacing: 0.08em;
  text-shadow:
    0 1px 3px #000,
    0 0 5px #000;
  opacity: 1;
  pointer-events: none;
}

.hotbar.drag-active .hotbar-assignment-hint {
  background: rgba(244, 220, 156, 0.98);
  color: #1f160b;
}

.hotbar-slot {
  position: relative;
  isolation: isolate;
  width: 66px;
  height: 66px;
  display: flex;
  align-items: center;
  justify-content: center;
  border: 1px solid rgb(43, 32, 19);
  background: transparent;
  box-shadow:
    inset 0 0 0 2px rgba(255, 247, 220, 0.25),
    0 5px 14px rgba(0, 0, 0, 0.48);
}

.hotbar-slot::before {
  content: "";
  position: absolute;
  inset: 0;
  z-index: -1;
  background: linear-gradient(
    rgba(226, 209, 169, 0.94),
    rgba(194, 168, 119, 0.94)
  );
  opacity: var(--hotbar-content-opacity);
  pointer-events: none;
}

.hotbar-slot.unavailable::before {
  opacity: calc(var(--hotbar-content-opacity) * 0.45);
}

.assignment-mode .hotbar-slot {
  cursor: default;
  transition:
    transform 120ms ease,
    box-shadow 120ms ease,
    border-color 120ms ease;
}

.assignment-mode .hotbar-slot.drop-ready {
  cursor: grabbing;
  border-color: rgb(105, 72, 25);
  box-shadow:
    inset 0 0 0 3px rgba(255, 249, 214, 0.75),
    0 0 22px rgba(238, 188, 74, 1);
  transform: translateY(-6px) scale(1.08);
  animation: hotbar-drop-pulse 700ms ease-in-out infinite alternate;
}

@keyframes hotbar-drop-pulse {
  from {
    filter: brightness(1);
  }
  to {
    filter: brightness(1.22);
  }
}

.hotbar-slot img {
  max-width: 48px;
  max-height: 48px;
  object-fit: contain;
  filter: invert(1) sepia(0.55) saturate(0.6) contrast(1.25) brightness(0.62);
  opacity: 1;
}

.hotbar-slot.unavailable img {
  opacity: 0.45;
}

.hotbar-key {
  position: absolute;
  z-index: 2;
  top: -1px;
  left: -1px;
  width: 21px;
  height: 21px;
  display: flex;
  align-items: center;
  justify-content: center;
  border-right: 1px solid rgb(43, 32, 19);
  border-bottom: 1px solid rgb(43, 32, 19);
  background: rgb(229, 211, 170);
  box-shadow: 1px 1px 2px rgba(0, 0, 0, 0.35);
  font-family: "Playfair Display", serif;
  font-size: 14px;
  font-weight: 800;
  line-height: 1;
  color: rgb(43, 32, 19);
  text-shadow: none;
  opacity: 1;
}

.hotbar-qty {
  position: absolute;
  right: 4px;
  bottom: 2px;
  font-size: 11px;
  color: #2b2013;
  opacity: var(--hotbar-content-opacity);
}
</style>
