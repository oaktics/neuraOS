import {performance} from 'node:perf_hooks';

// Workload completion is the final reader drain, not sampler shutdown or output
// validation. Still await shutdown so its errors cannot turn into false success.
export async function finishWorkload(readers, start, stopSampling, now=()=>performance.now()) {
 await Promise.all(readers);
 const completedAt=now();
 await stopSampling();
 return completedAt-start;
}
