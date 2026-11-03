<script setup>
import { t } from '@/i18n';
import { equipmentSlotLabel, equipmentOptionLabel } from '../equipmentPresentation.js';
defineProps({ options: { type: Array, required: true }, slots: { type: Array, default: () => [] }, busy: Boolean, message: String });
const emit = defineEmits(['change', 'close']);
</script>

<template>
  <div class="equipment-backdrop">
    <section class="equipment-panel" role="dialog" aria-modal="true" :aria-label="t('ui_equipment_title')">
      <p>{{ t('ui_equipment_title') }}</p>
      <p>{{ t('ui_equipment_help') }}</p>
      <template v-if="slots.length">
        <ul class="slot-overview" :aria-label="t('ui_equipment_slots')">
          <li v-for="slot in slots" :key="slot.slot" :class="'slot-' + slot.state">
            <span>{{ equipmentSlotLabel(slot, t) }}</span>
            <strong>{{ t('ui_equipment_' + (slot.state === 'selected' ? 'selected' : slot.state === 'occupied' ? 'occupied' : 'open')) }}</strong>
            <small v-if="slot.itemId">{{ t('ui_equipment_item', slot.itemId) }}</small>
          </li>
        </ul>
        <p class="slot-hint">{{ t('ui_equipment_hint') }}</p>
      </template>
      <p v-if="options.some(option => option.kind === 'attachment')">{{ t('ui_equipment_attachment_hint') }}</p>
      <p v-if="options.some(option => option.kind === 'repair')">{{ t('ui_equipment_repair_hint') }}</p>
      <button v-for="option in options" :key="`${option.kind || 'equipment'}:${option.action}:${option.slot}:${option.attachmentId || ''}`" :disabled="busy"
        @click="emit('change', option)">{{ equipmentOptionLabel(option, t) }}</button>
      <p v-if="message" role="status">{{ t(message) }}</p>
      <button :disabled="busy" @click="emit('close')">{{ t('ui_equipment_close') }}</button>
    </section>
  </div>
</template>

<style scoped>
.equipment-backdrop { position: fixed; inset: 0; z-index: 80; display: grid; place-items: center; background: #0006; }
.equipment-panel { width: min(520px, 90vw); max-height: 90vh; overflow-y: auto; padding: 24px; background: #e9ddbf; color: #2b2013; }
.slot-overview { list-style: none; padding: 0; margin: 0 0 12px; display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 6px; }
.slot-overview li { padding: 8px 10px; border: 1px solid #887554; display: flex; flex-wrap: wrap; justify-content: space-between; gap: 4px 8px; }
.slot-overview strong { font-size: 12px; }
.slot-overview small { flex-basis: 100%; font-size: 11px; }
.slot-open { background: #e1ead1; }
.slot-occupied { background: #ded1b9; }
.slot-selected { background: #d0dfe7; border-color: #436174 !important; }
.slot-hint { font-size: 12px; }
p { margin: 0 0 16px; line-height: 1.5; }
button { display: block; margin: 10px 0; padding: 10px 14px; border: 1px solid #685431; background: #f4ead1; cursor: pointer; }
button:disabled { opacity: .5; cursor: default; }
</style>
