import {test} from 'node:test';
import assert from 'node:assert/strict';
import {GitHubRefreshCache} from '../../apps/daemon/src/github-refresh.ts';

test('concurrent views share reads; manual refresh bypasses freshness',async()=>{
  let now=0,calls=0;
  const cache=new GitHubRefreshCache<number>(()=>60000,()=>now);
  const fetch=async()=>++calls;
  assert.deepEqual(await Promise.all([cache.read('repo:head',fetch),cache.read('repo:head',fetch,true)]),[1,1]);
  assert.equal(await cache.read('repo:head',fetch),1);
  assert.equal(await cache.read('repo:head',fetch,true),2);
  now=60001;assert.equal(await cache.read('repo:head',fetch),3);
  assert.equal(await cache.read('repo:new-head',fetch),4);
});
test('failures cool down even manual requests, then recover',async()=>{
  let now=0,calls=0;
  const cache=new GitHubRefreshCache<number>(()=>60000,()=>now);
  const fail=async()=>{calls++;throw new Error('offline');};
  await assert.rejects(cache.read('key',fail));
  await assert.rejects(cache.read('key',fail,true));assert.equal(calls,1);
  now=60000;assert.equal(await cache.read('key',async()=>42),42);
});
test('mutation invalidation detaches old requests without evicting unrelated repositories',async()=>{
  const cache=new GitHubRefreshCache<number>(()=>60000);
  let release!:(value:number)=>void;
  const old=cache.read('repo:head',()=>new Promise<number>(resolve=>{release=resolve;}));
  await Promise.resolve();
  await cache.read('other:head',async()=>9);
  cache.invalidate('repo:');
  assert.equal(await cache.read('repo:head',async()=>2),2);
  release(1);await old;
  assert.equal(await cache.read('repo:head',async()=>3),2);
  assert.equal(await cache.read('other:head',async()=>10),9);
});

test('distinct PR refreshes bound network concurrency',async()=>{
  const cache=new GitHubRefreshCache<number>(()=>60000);
  let active=0,maximum=0;
  await Promise.all(Array.from({length:12},(_,i)=>cache.read(String(i),async()=>{
    active++;maximum=Math.max(maximum,active);
    await new Promise(resolve=>setTimeout(resolve,5));active--;return i;
  })));
  assert.equal(maximum,4);
});
