<script setup>
import { t } from '@/i18n';
import { equipmentOptionLabel } from '../equipmentPresentation.js';
defineProps({ options: { type: Array, required: true }, slots: { type: Array, default: () => [] }, busy: Boolean, message: String });
const emit = defineEmits(['change', 'close']);
</script>

<template>
  <div class="equipment-backdrop">
    <section class="equipment-panel" role="dialog" aria-modal="true" :aria-busy="busy" :aria-label="t('ui_equipment_title')">
      <p>{{ t('ui_equipment_title') }}</p>
      <div v-if="busy" class="equipment-progress" role="status">
        <span class="equipment-spinner" aria-hidden="true"></span>
        <span>{{ t('ui_equipment_checking') }}</span>
      </div>
      <p v-if="options.some(option => option.kind === 'attachment')">{{ t('ui_equipment_attachment_hint') }}</p>
      <p v-if="options.some(option => option.kind === 'repair')">{{ t('ui_equipment_repair_hint') }}</p>
      <button v-for="option in options" :key="`${option.kind || 'equipment'}:${option.action}:${option.slot}:${option.attachmentId || ''}`" :disabled="busy"
        @click="emit('change', option)">{{ equipmentOptionLabel(option, t, true) }}</button>
      <p v-if="message && !busy" role="status">{{ t(message) }}</p>
      <button :disabled="busy" @click="emit('close')">{{ t('ui_equipment_close') }}</button>
    </section>
  </div>
</template>

<style scoped>
.equipment-backdrop { position: fixed; inset: 0; z-index: 80; display: grid; place-items: center; background: #0006; }
.equipment-panel { width: min(360px, 90vw); max-height: 90vh; overflow-y: auto; padding: 24px; background: #e9ddbf; color: #2b2013; }
p { margin: 0 0 16px; line-height: 1.5; }
button { display: block; width: 100%; text-align: left; margin: 8px 0; padding: 12px 14px; border: 1px solid #685431; background: #f4ead1; cursor: pointer; }
button:disabled { opacity: .5; cursor: default; }
.equipment-progress { display: flex; align-items: center; gap: 10px; margin-bottom: 16px; }
.equipment-spinner { width: 18px; height: 18px; flex-shrink: 0; border: 2px solid #68543140; border-top-color: #685431; border-radius: 50%; animation: equipment-spin .8s linear infinite; }
@keyframes equipment-spin { to { transform: rotate(360deg); } }
@media (prefers-reduced-motion: reduce) { .equipment-spinner { animation: none; } }
</style>
