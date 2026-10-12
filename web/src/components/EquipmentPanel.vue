<script setup>
defineProps({ options: { type: Array, required: true }, busy: Boolean, message: String });
const emit = defineEmits(['change', 'close']);
</script>

<template>
  <div class="equipment-backdrop">
    <section class="equipment-panel" role="dialog" aria-modal="true" aria-label="Equipment">
      <p>Equipment</p>
      <p>Choose where to carry this firearm. Ammunition stays in your shared carried pools.</p>
      <button v-for="option in options" :key="`${option.action}:${option.slot}`" :disabled="busy"
        @click="emit('change', option)">{{ option.label }}</button>
      <p v-if="message" role="status">{{ message }}</p>
      <button :disabled="busy" @click="emit('close')">Close</button>
    </section>
  </div>
</template>

<style scoped>
.equipment-backdrop { position: fixed; inset: 0; z-index: 80; display: grid; place-items: center; background: #0006; }
.equipment-panel { width: min(430px, 90vw); padding: 24px; background: #e9ddbf; color: #2b2013; }
p { margin: 0 0 16px; line-height: 1.5; }
button { display: block; margin: 10px 0; padding: 10px 14px; border: 1px solid #685431; background: #f4ead1; cursor: pointer; }
button:disabled { opacity: .5; cursor: default; }
</style>
