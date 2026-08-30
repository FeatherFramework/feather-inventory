<script setup>
import { computed } from 'vue';
import { t } from '@/i18n';

const props = defineProps({
  x: { type: Number, required: true },
  y: { type: Number, required: true },
  canUse: { type: Boolean, default: false },
  canAssignHotbar: { type: Boolean, default: false },
  // Only meaningful for a compartment holding more than one unit -- splitting
  // a single item, or the whole stack, is just a move (see the server's
  // SplitStack RPC, which rejects both).
  canSplit: { type: Boolean, default: false },
});

const emit = defineEmits(['use', 'assignHotbar', 'give', 'drop', 'split', 'close']);

// Keep the menu on-screen near the click point rather than letting it run
// off the right/bottom edge -- flip anchor side instead of clamping
// position so it never overlaps the cursor.
const style = computed(() => {
  const flipX = props.x > window.innerWidth - 160;
  const flipY = props.y > window.innerHeight - 190;
  return {
    left: flipX ? 'auto' : props.x + 'px',
    right: flipX ? window.innerWidth - props.x + 'px' : 'auto',
    top: flipY ? 'auto' : props.y + 'px',
    bottom: flipY ? window.innerHeight - props.y + 'px' : 'auto',
  };
});
</script>

<template>
  <div class="ctx-backdrop" @click="emit('close')" @contextmenu.prevent="emit('close')"></div>
  <div class="ctx-menu" :style="style">
    <div v-if="canUse" class="ctx-item" @click="(event) => emit('use', event)">{{ t('ui_use') }}</div>
    <div v-if="canAssignHotbar" class="ctx-item" @click="emit('assignHotbar')">{{ t('ui_assign_hotbar') }}</div>
    <div class="ctx-item" @click="(event) => emit('give', event)">{{ t('ui_give') }}</div>
    <div class="ctx-item" @click="(event) => emit('drop', event)">{{ t('ui_drop') }}</div>
    <div v-if="canSplit" class="ctx-item" @click="(event) => emit('split', event)">{{ t('ui_split') }}</div>
  </div>
</template>

<style scoped>
.ctx-backdrop {
  position: fixed;
  inset: 0;
  z-index: 60;
}

.ctx-menu {
  position: fixed;
  z-index: 61;
  min-width: 140px;
  background: #e9ddbf;
  border: 1px solid rgba(43, 32, 19, 0.45);
  box-shadow: 0 8px 20px rgba(0, 0, 0, 0.5);
  color: #2b2013;
  user-select: none;
}

.ctx-item {
  padding: 9px 18px;
  cursor: pointer;
  font-family: 'Playfair Display', serif;
  font-weight: 500;
  font-size: 14px;
  letter-spacing: 0.05em;
}

.ctx-item:hover {
  background: rgba(90, 68, 34, 0.18);
}

.ctx-item + .ctx-item {
  border-top: 1px solid rgba(43, 32, 19, 0.25);
}
</style>
