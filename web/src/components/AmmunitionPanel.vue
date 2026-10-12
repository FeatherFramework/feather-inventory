<script setup>
import { computed, ref } from 'vue';
const props = defineProps({ options: { type: Array, required: true }, busy: Boolean, message: String });
const emit = defineEmits(['transfer', 'close']);
const selected = ref(props.options[0]?.id || '');
const quantity = ref(1);
const option = computed(() => props.options.find((entry) => entry.id === selected.value));
const valid = computed(() => Number.isInteger(Number(quantity.value)) && Number(quantity.value) > 0 && Number(quantity.value) <= 1000);
</script>
<template>
  <div class="ammo-shade">
    <section class="ammo-panel" role="dialog" aria-label="Ammunition" aria-modal="true">
      <h2>Ammunition</h2>
      <p>Load loose rounds into your shared carried pool. Unload returns carried rounds to Inventory.</p>
      <!-- Keep selection inside the NUI document: native select popups can
           leave a corrupted compositor surface in the embedded game browser. -->
      <div class="ammo-types" role="group" aria-label="Ammunition type">
        <button v-for="entry in options" :key="entry.id" type="button" :disabled="busy"
          :aria-pressed="selected === entry.id" :class="{ selected: selected === entry.id }"
          @click="selected = entry.id">{{ entry.label }} <span>{{ entry.loose ?? '?' }} loose · {{ entry.carried }} carried</span></button>
      </div>
      <p>Loose: {{ option?.loose ?? '?' }} · Carried: {{ option?.carried ?? 0 }}</p>
      <label>Rounds <input v-model.number="quantity" type="number" min="1" max="1000" step="1" :disabled="busy"></label>
      <p role="status">{{ busy ? 'Waiting for saved state and native acknowledgement…' : message }}</p>
      <div class="ammo-buttons">
        <button :disabled="busy || !valid || !option || option.loose == null || quantity > option.loose" @click="emit('transfer', selected, Number(quantity), 'load')">Load</button>
        <button :disabled="busy || !valid || !option || quantity > option.carried" @click="emit('transfer', selected, Number(quantity), 'unload')">Unload</button>
        <button :disabled="busy" @click="emit('close')">Close</button>
      </div>
      <small>Reload normally in-game. This does not choose a weapon's ammo type.</small>
    </section>
  </div>
</template>
<style scoped>
.ammo-shade { position: fixed; inset: 0; z-index: 75; background: #0008; display: grid; place-items: center; }
.ammo-panel { width: min(480px, 90vw); padding: 24px; background: #e9ddbf; color: #2b2013; border: 1px solid #5a4422; box-shadow: 0 8px 24px #0008; }
.ammo-panel h2 { margin: 0 0 12px; }
.ammo-panel label { display: grid; gap: 6px; }
.ammo-panel input { padding: 8px; color: #2b2013; background: #fff8; }
.ammo-types { max-height: 180px; overflow-y: auto; border: 1px solid #5a4422; }
.ammo-types button { display: flex; justify-content: space-between; gap: 12px; width: 100%; padding: 9px; text-align: left; color: #2b2013; background: #f3e8ce; border: 0; border-bottom: 1px solid #5a442233; cursor: pointer; }
.ammo-types button.selected { background: #d2bd89; font-weight: bold; box-shadow: inset 4px 0 #5a4422; }
.ammo-types button:disabled { opacity: .5; }
.ammo-types span { white-space: nowrap; font-size: 12px; }
.ammo-buttons { display: flex; gap: 12px; margin: 16px 0; }
.ammo-buttons button { padding: 8px 16px; border: 1px solid #5a4422; background: #fff6; cursor: pointer; }
.ammo-buttons button:disabled { opacity: .5; cursor: default; }
</style>
