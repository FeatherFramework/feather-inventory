import { nextTick } from 'vue';

let sequence = 0;

export function beginMutationTrace() {
  return { traceId: `nui-${Date.now()}-${++sequence}`, started: performance.now() };
}

// Two animation frames approximate a paint opportunity after Vue applies the
// authoritative response. They do not prove that the game compositor painted.
// Logging is detached so a hidden NUI cannot hold up the mutation promise.
export function finishMutationTrace(trace, response) {
  if (!response?.mutationTiming) return;
  const appliedMs = performance.now() - trace.started;
  const summary = { ...response.mutationTiming, browserAppliedMs: +appliedMs.toFixed(2) };
  nextTick().then(() => {
    requestAnimationFrame(() => requestAnimationFrame(() => {
      console.log('[inventory:mutation] ' + JSON.stringify({
        ...summary,
        browserFrameMs: +(performance.now() - trace.started).toFixed(2),
      }));
    }));
  });
}
