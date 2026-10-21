<script setup>
defineProps({ options: { type: Array, required: true }, slots: { type: Array, default: () => [] }, busy: Boolean, message: String });
const emit = defineEmits(['change', 'close']);
</script>

<template>
  <div class="equipment-backdrop">
    <section class="equipment-panel" role="dialog" aria-modal="true" aria-label="Equipment">
      <p>Equipment</p>
      <p>Choose where to carry this weapon. Ammunition stays in your shared carried pools.</p>
      <template v-if="slots.length">
        <ul class="slot-overview" aria-label="Equipment slot occupancy">
          <li v-for="slot in slots" :key="slot.slot" :class="'slot-' + slot.state">
            <span>{{ slot.label }}</span>
            <strong>{{ slot.state === 'selected' ? 'This item' : slot.state === 'occupied' ? 'Occupied' : 'Open' }}</strong>
            <small v-if="slot.itemId">Item #{{ slot.itemId }}</small>
          </li>
        </ul>
        <p class="slot-hint">Open means empty, not necessarily compatible. Only permitted actions appear below. Only one lasso can be equipped.</p>
      </template>
      <p v-if="options.some(option => option.kind === 'attachment')">Installing an attachment uses one matching item. Removal returns it to your inventory.</p>
      <p v-if="options.some(option => option.kind === 'repair')">Cleaning uses the listed material. Permanent wear cannot be repaired away.</p>
      <button v-for="option in options" :key="`${option.kind || 'equipment'}:${option.action}:${option.slot}:${option.attachmentId || ''}`" :disabled="busy"
        @click="emit('change', option)">{{ option.label }}</button>
      <p v-if="message" role="status">{{ message }}</p>
      <button :disabled="busy" @click="emit('close')">Close</button>
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
