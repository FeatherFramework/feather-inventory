<script setup>
import { t } from '@/i18n';

const props = defineProps({
  itemName: { type: String, required: true },
  slots: { type: Number, default: 6 },
  bindings: { type: Array, default: () => [] },
});
const emit = defineEmits(['select', 'clear', 'cancel']);

function bindingFor(slot) {
  return props.bindings.find((binding) => Number(binding.slot) === slot) || null;
}
</script>

<template>
  <div class="hotbar-modal-backdrop" @click="emit('cancel')" @contextmenu.prevent="emit('cancel')"></div>
  <div class="hotbar-modal">
    <div class="hotbar-modal-title">{{ t('ui_assign_hotbar') }} &mdash; {{ itemName }}</div>
    <div class="hotbar-modal-subtitle">{{ t('ui_choose_hotbar_slot') }}</div>
    <div class="hotbar-modal-slots">
      <div v-for="slot in slots" :key="slot" class="hotbar-modal-slot">
        <button type="button" @click="emit('select', slot)">
          SHIFT+{{ slot }}<span v-if="bindingFor(slot)"><br />{{ bindingFor(slot).displayName }}</span>
        </button>
        <button v-if="bindingFor(slot)" type="button" class="hotbar-modal-clear" @click="emit('clear', slot)">
          &times;
        </button>
      </div>
    </div>
    <button type="button" class="hotbar-modal-cancel" @click="emit('cancel')">{{ t('ui_cancel') }}</button>
  </div>
</template>

<style scoped>
.hotbar-modal-backdrop {
  position: fixed;
  inset: 0;
  z-index: 70;
  background: rgba(18, 14, 10, 0.55);
}

.hotbar-modal {
  position: fixed;
  z-index: 71;
  top: 50%;
  left: 50%;
  transform: translate(-50%, -50%);
  width: 320px;
  padding: 20px 22px;
  color: #2b2013;
  background: #e9ddbf;
  border: 1px solid rgba(43, 32, 19, 0.45);
  box-shadow: 0 12px 30px rgba(0, 0, 0, 0.6);
  font-family: 'Old Standard TT', serif;
  text-align: center;
}

.hotbar-modal-title {
  font-family: 'Playfair Display', serif;
  font-weight: 700;
  font-size: 18px;
}

.hotbar-modal-subtitle {
  margin-top: 6px;
  color: #5c4a30;
}

.hotbar-modal-slots {
  margin-top: 16px;
  display: grid;
  grid-template-columns: repeat(3, 1fr);
  gap: 8px;
}

.hotbar-modal button {
  padding: 9px 6px;
  color: #2b2013;
  background: rgba(255, 255, 255, 0.22);
  border: 1px solid rgba(43, 32, 19, 0.4);
  font-family: 'Playfair Display', serif;
  cursor: pointer;
}

.hotbar-modal button:hover {
  background: rgba(90, 68, 34, 0.18);
}

.hotbar-modal-slot {
  position: relative;
}

.hotbar-modal-slot > button:first-child {
  width: 100%;
  min-height: 48px;
}

.hotbar-modal-slot .hotbar-modal-clear {
  position: absolute;
  top: -5px;
  right: -5px;
  width: 20px;
  height: 20px;
  padding: 0;
  border-radius: 50%;
  background: #d5c197;
}

.hotbar-modal-cancel {
  width: 100%;
  margin-top: 12px;
}
</style>
