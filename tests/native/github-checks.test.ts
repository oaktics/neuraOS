import {test} from 'node:test';
import assert from 'node:assert/strict';
import {ChecksCache,parseChecks,summarizeChecks,type CISnapshot} from '../../apps/daemon/src/github-checks.ts';
import {GitHub} from '../../apps/daemon/src/github.ts';

const head='a'.repeat(40),nextHead='b'.repeat(40);
const page=(nodes:unknown[])=>({data:{repository:{object:{oid:head,statusCheckRollup:{contexts:{nodes}}}}}});
test('CI summary distinguishes running, errors, cancellation, absent checks and unknown states',()=>{
  const state=(...states:string[])=>summarizeChecks(states.map(state=>({name:'test',state,url:null})));
  assert.equal(state(),'none');
  assert.equal(state('SUCCESS','IN_PROGRESS'),'running');
  assert.equal(state('SUCCESS','SKIPPED','NEUTRAL'),'success');
  assert.equal(state('FAILURE','QUEUED'),'failure');
  assert.equal(state('ACTION_REQUIRED'),'failure');
  assert.equal(state('CANCELLED'),'cancelled');
  assert.equal(state('COMPLETED'),'unknown');
});
test('paginated checks include both Checks and commit statuses; missing commits are not successful',()=>{
  const value=parseChecks([page([{name:'build',status:'COMPLETED',conclusion:'SUCCESS'}]),page([{context:'legacy',state:'PENDING'}])],head);
  assert.equal(value.state,'running');assert.equal(value.checks.length,2);
  assert.deepEqual(parseChecks([{data:{repository:{object:null}}}],head),{state:'unpublished',checks:[]});
  assert.throws(()=>parseChecks([{data:{repository:null}}],head));
  assert.throws(()=>parseChecks([page([])],nextHead));
});
test('cache coalesces requests and caches failure without presenting stale success',async()=>{
  const cache=new ChecksCache(0);let calls=0;
  const read=async():Promise<CISnapshot>=>{calls++;await new Promise(r=>setTimeout(r,10));return {state:'success',checks:[],fetchedAt:new Date().toISOString()};};
  await Promise.all([cache.read('repo:head',read),cache.read('repo:head',read)]);assert.equal(calls,1);
  const failed=await cache.read('repo:head',async()=>{throw new Error('private detail');});
  assert.equal(failed.state,'unavailable');assert.ok(!failed.message?.includes('private detail'));
  const cooldown=new ChecksCache();calls=0;
  const fail=async():Promise<CISnapshot>=>{calls++;throw new Error('offline');};
  await cooldown.read('repo:head',fail);await cooldown.read('repo:head',fail);assert.equal(calls,1);
});
test('CI background network concurrency is bounded',async()=>{
  const cache=new ChecksCache();let active=0,max=0;
  await Promise.all(Array.from({length:12},(_,i)=>cache.read(String(i),async()=>{
    active++;max=Math.max(max,active);await new Promise(r=>setTimeout(r,5));active--;
    return {state:'none',checks:[],fetchedAt:''};
  })));
  assert.equal(max,4);
});
test('CI binds to exact local HEAD and invalidates a result when HEAD changes during fetch',async()=>{
  let current=head,calls=0,move=false;
  const git=async(_root:string,args:string[])=>args[0]==='remote'?'git@github.com:owner/repo.git':args[0]==='branch'?'feature':current;
  const github=new GitHub(async(_root,args)=>{
    calls++;assert.ok(args.includes(`head=${head}`));assert.ok(args.includes('--paginate'));
    if(move)current=nextHead;
    return JSON.stringify([page([{name:'build',status:'COMPLETED',conclusion:'SUCCESS'}])]);
  },git);
  assert.equal((await github.checks('/repo')).state,'success');
  assert.equal((await github.checks('/another-worktree-same-head')).state,'success');assert.equal(calls,1);
  const changed=new GitHub(async()=>{current=nextHead;return JSON.stringify([page([])]);},git);
  assert.equal((await changed.checks('/repo')).state,'unknown');
});

test('checks endpoint is authenticated and does not fetch GitHub for ordinary folders',async()=>{
  const {mkdtemp,rm}=await import('node:fs/promises');
  const {tmpdir}=await import('node:os');
  const {join}=await import('node:path');
  const {randomUUID}=await import('node:crypto');
  const {createDaemon}=await import('../../apps/daemon/src/server.ts');
  const dir=await mkdtemp(join(tmpdir(),'neura-checks-http-'));
  let calls=0;
  const github=new GitHub(async()=>{calls++;throw new Error('unexpected GitHub call');});
  const daemon=await createDaemon(dir,github),id=randomUUID();
  daemon.store.put('workspaces',{id,projectId:randomUUID(),name:'folder',path:dir,branch:'',kind:'folder',createdAt:''});
  try{
    assert.equal((await daemon.app.inject(`/v1/workspaces/${id}/checks`)).statusCode,401);
    const response=await daemon.app.inject({url:`/v1/workspaces/${id}/checks`,headers:{authorization:`Bearer ${daemon.token}`}});
    assert.equal(response.statusCode,200);assert.equal(response.json().state,'unsupported');assert.equal(calls,0);
  }finally{await daemon.app.close();await rm(dir,{recursive:true,force:true});}
});
