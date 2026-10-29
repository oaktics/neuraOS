import {test} from 'node:test';
import assert from 'node:assert/strict';
import {correlate} from '../../scripts/native/analyze-latency.mjs';
test('timeout joins request stages and adjacent pressure without attributing a cause',()=>{
 const time='2026-10-30T00:00:00.000Z';
 const rows=correlate([{requestId:'one',time,elapsedMs:1000,status:'timeout-or-transport'}],
 [{requestId:'other',event:'http.received'},
 {requestId:'one',event:'http.received'},
 {requestId:'one',event:'store.queue.begin'},
 {requestId:'one',event:'store.sqlite.begin'},
 {requestId:'one',event:'store.commit.begin',droppedEvents:2}],
 [{time},{time:'2026-10-29T23:59:00.000Z'}]);
 assert.equal(rows.length,1);assert.equal(rows[0].httpComplete,false);
 assert.equal(rows[0].intervals.length,4);assert.equal(rows[0].pressure.length,1);
 assert.equal(rows[0].droppedEvents,2);assert.equal(rows[0].cause,undefined);
});

import {spawn} from 'node:child_process';
import {mkdtemp,readFile,rm} from 'node:fs/promises';
import {existsSync} from 'node:fs';
import {join,resolve} from 'node:path';
import {tmpdir} from 'node:os';
import {createServer} from 'node:net';
import {request} from 'node:http';
import {randomUUID} from 'node:crypto';
import {setTimeout as sleep} from 'node:timers/promises';
const binary=resolve(process.env.NEURA_NATIVE_DAEMON??'crates/native-core/target/release/neura-native-core');
test('HTTP timeout correlation survives incomplete body and exports no body/header secret',{skip:!existsSync(binary),timeout:20000},async()=>{
 const root=await mkdtemp(join(tmpdir(),'neura-trace-http-'));
 const listener=createServer();await new Promise(r=>listener.listen(0,'127.0.0.1',r));const port=listener.address().port;await new Promise(r=>listener.close(r));
 const trace=join(root,'trace'),base=`http://127.0.0.1:${port}`;
 const child=spawn(binary,[],{env:{...process.env,NEURA_DEV_DATA_DIR:root,NEURA_DEV_PORT:String(port),NEURA_PERF_TRACE_DIR:trace},stdio:'ignore'});
 const exit=new Promise(r=>child.once('exit',r));let hanging;
 const rows=async()=>{try{return(await readFile(join(trace,'daemon.jsonl'),'utf8')).trim().split('\n').filter(Boolean).map(JSON.parse);}catch(e){if(e.code==='ENOENT')return [];throw e;}};
 const until=async check=>{for(let i=0;i<200;i++){if(await check())return;await sleep(20);}assert.fail('fixture did not reach barrier');};
 try{
  let token;
  await until(async()=>{try{token=(await readFile(join(root,'daemon-token'),'utf8')).trim();return(await fetch(base+'/v1/state',{headers:{authorization:`Bearer ${token}`},signal:AbortSignal.timeout(200)})).ok;}catch{return false;}});
  const id=randomUUID();
  hanging=request(base+'/v1/commands',{method:'POST',headers:{authorization:`Bearer ${token}`,'content-type':'application/json','x-neura-perf-id':id}});
  hanging.on('error',()=>{});hanging.write('{"secret":"private-prompt-secret');
  await until(async()=>(await rows()).some(r=>r.requestId===id&&r.event==='http.received'));
  hanging.destroy(); // Client deadline while the body/handler remains incomplete.
  const readId=randomUUID();
  assert.equal((await fetch(base+'/v1/state',{headers:{authorization:`Bearer ${token}`,'x-neura-perf-id':readId}})).status,200);
  await fetch(base+'/v1/state',{headers:{authorization:`Bearer ${token}`,'x-neura-perf-id':'private-prompt-secret'}});
  child.kill('SIGTERM');assert.equal(await exit,0);
  const events=await rows(),stages=events.filter(r=>r.requestId===readId).map(r=>r.event);
  for(const phase of ['http.received','store.queue.begin','store.sqlite.begin','store.sqlite.end','http.response'])assert.ok(stages.includes(phase),phase);
  assert.ok(stages.indexOf('store.sqlite.end')<stages.indexOf('http.response'));
  const joined=correlate([{requestId:id,time:new Date().toISOString(),elapsedMs:1,status:'timeout-or-transport'}],events,[]);
  assert.ok(joined[0].intervals.some(r=>r.event==='http.received'));
  assert.ok(!JSON.stringify(events).includes('private-prompt-secret'));assert.ok(!JSON.stringify(events).includes(token));
 }finally{hanging?.destroy();if(child.exitCode===null){child.kill('SIGKILL');await exit;}await rm(root,{recursive:true,force:true});}
});
