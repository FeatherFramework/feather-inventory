<script setup>
import { ref } from 'vue';

// Quantity prompt for Drop/Give on a stacked compartment (>1 unit) --
// single-item/non-stackable compartments skip this entirely and act
// immediately (see App.vue's onContextDrop/onContextGive).
const props = defineProps({
  itemName: { type: String, required: true },
  actionLabel: { type: String, required: true }, // "Drop" | "Give"
  max: { type: Number, required: true },
});

const emit = defineEmits(['confirm', 'cancel']);

const amount = ref(Math.min(1, props.max) || 1);
const error = ref('');

function clamp(value) {
  const n = Math.floor(Number(value));
  if (!Number.isFinite(n)) return 1;
  return Math.min(Math.max(n, 1), props.max);
}

function dec() {
  amount.value = clamp(amount.value - 1);
}

function inc() {
  amount.value = clamp(amount.value + 1);
}

function setAll() {
  amount.value = props.max;
}

function onConfirm() {
  error.value = '';
  const value = clamp(amount.value);
  if (value < 1 || value > props.max) {
    error.value = 'Invalid amount.';
    return;
  }
  emit('confirm', value);
}
</script>

<template>
  <div class="qty-backdrop" @click="emit('cancel')" @contextmenu.prevent="emit('cancel')"></div>
  <div class="qty-modal">
    <div class="qty-title">{{ actionLabel }} &mdash; {{ itemName }}</div>
    <div class="qty-subtitle">How many? (1&#8211;{{ max }})</div>

    <div class="qty-stepper">
      <div class="qty-step-btn" @click="dec">&minus;</div>
      <input
        type="number"
        class="qty-input"
        :min="1"
        :max="max"
        v-model.number="amount"
        @change="amount = clamp(amount)"
      />
      <div class="qty-step-btn" @click="inc">&plus;</div>
    </div>

    <div class="qty-all" @click="setAll">Use all ({{ max }})</div>

    <div v-if="error" class="qty-error">{{ error }}</div>

    <div class="qty-actions">
      <div class="qty-btn" @click="emit('cancel')">Cancel</div>
      <div class="qty-btn qty-confirm" @click="onConfirm">{{ actionLabel }}</div>
    </div>
  </div>
</template>

<style scoped>
.qty-backdrop {
  position: fixed;
  inset: 0;
  z-index: 70;
  background: rgba(18, 14, 10, 0.55);
}

.qty-modal {
  position: fixed;
  z-index: 71;
  top: 50%;
  left: 50%;
  transform: translate(-50%, -50%);
  width: 280px;
  background: #e9ddbf;
  border: 1px solid rgba(43, 32, 19, 0.45);
  box-shadow: 0 12px 30px rgba(0, 0, 0, 0.6);
  color: #2b2013;
  padding: 20px 22px;
  font-family: 'Old Standard TT', serif;
  user-select: none;
}

.qty-title {
  font-family: 'Playfair Display', serif;
  font-weight: 700;
  font-size: 19px;
  letter-spacing: 0.03em;
  text-align: center;
}

.qty-subtitle {
  margin-top: 6px;
  font-size: 14px;
  text-align: center;
  color: #5c4a30;
}

.qty-stepper {
  margin-top: 16px;
  display: flex;
  align-items: center;
  justify-content: center;
  gap: 10px;
}

.qty-step-btn {
  width: 32px;
  height: 32px;
  display: flex;
  align-items: center;
  justify-content: center;
  border: 1px solid rgba(43, 32, 19, 0.45);
  color: #2b2013;
  font-family: 'Playfair Display', serif;
  font-size: 18px;
  line-height: 1;
  cursor: pointer;
}

.qty-step-btn:hover {
  background: rgba(90, 68, 34, 0.18);
}

.qty-input {
  width: 64px;
  text-align: center;
  background: rgba(255, 255, 255, 0.35);
  border: 1px solid rgba(43, 32, 19, 0.45);
  color: #2b2013;
  font-family: 'Playfair Display', serif;
  font-size: 18px;
  padding: 4px 0;
}

.qty-input:focus {
  outline: none;
  border-color: #2b2013;
}

/* Hide the native spinner -- the +/- buttons above replace it, and the
   default browser control doesn't match the theme at all. */
.qty-input::-webkit-inner-spin-button,
.qty-input::-webkit-outer-spin-button {
  -webkit-appearance: none;
  margin: 0;
}

.qty-all {
  margin-top: 10px;
  text-align: center;
  font-size: 12px;
  letter-spacing: 0.05em;
  text-decoration: underline;
  cursor: pointer;
  color: #5c4a30;
}

.qty-all:hover {
  color: #2b2013;
}

.qty-error {
  margin-top: 10px;
  text-align: center;
  font-size: 13px;
  color: #7d1f18;
}

.qty-actions {
  margin-top: 18px;
  display: flex;
  gap: 10px;
}

.qty-btn {
  flex: 1;
  text-align: center;
  padding: 8px 0;
  border: 1px solid rgba(43, 32, 19, 0.45);
  cursor: pointer;
  font-family: 'Playfair Display', serif;
  font-weight: 500;
  font-size: 14px;
  letter-spacing: 0.04em;
}

.qty-btn:hover {
  background: rgba(90, 68, 34, 0.12);
}

.qty-confirm {
  background: rgba(90, 68, 34, 0.18);
}

.qty-confirm:hover {
  background: rgba(90, 68, 34, 0.3);
}
</style>
