import {test} from 'node:test';
import assert from 'node:assert/strict';
import {finishWorkload} from '../../scripts/native/benchmark-timing.mjs';
const deferred=()=>{let resolve,reject;const promise=new Promise((r,j)=>{resolve=r;reject=j;});return {promise,resolve,reject};};

for(const shutdownMs of [250,1250])test(`workload duration excludes ${shutdownMs}ms sampler tail and still waits for shutdown`,async()=>{
 let now=1000,finished=false,stopping=false;
 const reader=deferred(),sampler=deferred(),shutdownStarted=deferred();
 const result=finishWorkload([Promise.resolve(),reader.promise],now,async()=>{
  stopping=true;shutdownStarted.resolve();await sampler.promise;
 },()=>now).then(duration=>{finished=true;return duration;});
 await Promise.resolve();assert.equal(stopping,false,'do not stop sampling before the final reader drains');
 now+=50;reader.resolve();await shutdownStarted.promise;
 assert.equal(finished,false,'sampler shutdown must still be awaited');
 now+=shutdownMs;sampler.resolve();
 assert.equal(await result,50,'sleep or metrics subprocess shutdown must not inflate PTY completion');
});

test('sampler failure is not hidden by a completed workload measurement',async()=>{
 await assert.rejects(finishWorkload([Promise.resolve()],0,async()=>{throw Error('metrics failed');},()=>50),/metrics failed/);
});
