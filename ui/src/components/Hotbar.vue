<script setup>
const props = defineProps({
  slots: { type: Number, default: 6 },
  bindings: { type: Array, default: () => [] },
});

function bindingFor(slot) {
  return props.bindings.find((binding) => Number(binding.slot) === slot) || null;
}

function iconSrc(name) {
  return `images/items/${name}.png`;
}

function onIconError(event) {
  event.target.style.display = 'none';
}
</script>

<template>
  <div class="hotbar" aria-label="Inventory hotbar">
    <div v-for="slot in slots" :key="slot" class="hotbar-slot" :class="{ unavailable: bindingFor(slot) && !bindingFor(slot).available }">
      <div class="hotbar-key">SHIFT+{{ slot }}</div>
      <img
        v-if="bindingFor(slot)"
        :src="iconSrc(bindingFor(slot).itemName)"
        :alt="bindingFor(slot).displayName"
        @error="onIconError"
      />
      <div v-if="bindingFor(slot)?.quantity > 1" class="hotbar-qty">&times;{{ bindingFor(slot).quantity }}</div>
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
  font-family: 'Old Standard TT', serif;
}

.hotbar-slot {
  position: relative;
  width: 66px;
  height: 66px;
  display: flex;
  align-items: center;
  justify-content: center;
  border: 1px solid rgba(43, 32, 19, 0.72);
  background: linear-gradient(rgba(226, 209, 169, 0.94), rgba(194, 168, 119, 0.94));
  box-shadow: inset 0 0 0 2px rgba(255, 247, 220, 0.25), 0 5px 14px rgba(0, 0, 0, 0.48);
}

.hotbar-slot.unavailable {
  opacity: 0.45;
}

.hotbar-slot img {
  max-width: 48px;
  max-height: 48px;
  object-fit: contain;
  filter: invert(1) sepia(0.55) saturate(0.6) contrast(1.25) brightness(0.62);
}

.hotbar-key {
  position: absolute;
  top: 2px;
  left: 4px;
  font-family: 'Playfair Display', serif;
  font-size: 8px;
  letter-spacing: 0.02em;
  color: #4a3a24;
}

.hotbar-qty {
  position: absolute;
  right: 4px;
  bottom: 2px;
  font-size: 11px;
  color: #2b2013;
}
</style>

