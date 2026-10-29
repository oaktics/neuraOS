import {test} from 'node:test';
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {mkdtemp,mkdir,writeFile,readFile,realpath,rm} from 'node:fs/promises';
import {join,resolve} from 'node:path';
import {tmpdir} from 'node:os';
import {fileURLToPath} from 'node:url';
import {createServer} from 'node:net';
import {randomUUID} from 'node:crypto';
import {setTimeout as delay} from 'node:timers/promises';
import WebSocket from 'ws';
const binary=process.env.NEURA_NATIVE_DAEMON;
const quote=s=>"'"+s.replaceAll("'","'\\''")+"'";
async function until(check,label){const end=Date.now()+15000;do{if(await check())return;await delay(25);}while(Date.now()<end);assert.fail(`deadline: ${label}`);}

// This exercises the actual Rust HTTP -> ProviderService.prepare -> managed CLI/PTY path.
// Fake CLIs implement only the external provider wire protocol: no credentials/model calls.
// Counts are test points, not admission limits; both providers reach count live sessions.
test('actual native daemon launches fake Claude and Codex at 10/20/32 concurrency', {skip:!binary,timeout:180000},async t=>{
 const root=await realpath(await mkdtemp(join(tmpdir(),'neura-provider-daemon-'))),home=join(root,'home'),data=join(root,'data'),folder=join(root,'folder'),bin=join(home,'.local/bin');
 await mkdir(bin,{recursive:true});await mkdir(folder);
 const fixture=fileURLToPath(new URL('./fixtures/provider-daemon-cli.mjs',import.meta.url));
 for(const provider of ['claude','codex'])await writeFile(join(bin,provider),`#!/bin/sh\nexec ${quote(process.execPath)} ${quote(fixture)} ${provider} "$@"\n`,{mode:0o700});
 const listener=createServer();await new Promise(r=>listener.listen(0,'127.0.0.1',r));const port=listener.address().port;await new Promise(r=>listener.close(r));
 const base=`http://127.0.0.1:${port}`,env={HOME:home,PATH:bin+':/usr/bin:/bin',LANG:'en_US.UTF-8',TMPDIR:root,NEURA_DEV_DATA_DIR:data,NEURA_DEV_PORT:String(port),NEURA_CLAUDE_PATH:join(bin,'claude'),NEURA_CODEX_PATH:join(bin,'codex')};
 const child=spawn(resolve(binary),[],{cwd:root,env,stdio:['ignore','pipe','pipe'],detached:true});let logs='',token,failed=false;const evidence={root,checks:[],ok:false};
 for(const s of [child.stdout,child.stderr])s.on('data',b=>logs=(logs+b).slice(-8192));
 const ended=new Promise(r=>child.once('exit',(code,signal)=>r({code,signal})));let spawnError;child.once('error',e=>spawnError=e);
 const request=async(path,body)=>{const r=await fetch(base+path,{method:body===undefined?'GET':'POST',headers:{authorization:`Bearer ${token}`,'content-type':'application/json'},body:body===undefined?undefined:JSON.stringify(body),signal:AbortSignal.timeout(20000)});const value=await r.json();assert.equal(r.status,200,JSON.stringify(value));return value;};
 const command=c=>request('/v1/commands',{operationId:randomUUID(),command:c});
 const sockets=new Set();
 async function stream(){const events=[];const ws=new WebSocket(base.replace('http:','ws:')+'/v1/stream',{headers:{authorization:`Bearer ${token}`}});sockets.add(ws);ws.on('message',b=>events.push(JSON.parse(b)));ws.on('error',()=>{});await until(()=>events.some(e=>e.type==='ready'),'WS ready');return {ws,events};}
 const output=(id,after=0)=>request(`/v1/terminals/${id}/output?after=${after}&chunksOnly=true`);
 const text=o=>o.chunks.map(c=>c.data).join('');
 try{
  await until(async()=>{if(spawnError)throw spawnError;assert.equal(child.exitCode,null,logs);try{token=(await readFile(join(data,'daemon-token'),'utf8')).trim();return (await request('/v1/state')).runtime==='rust';}catch{return false;}},'native startup');
  const project=await command({type:'project.add',path:folder});const workspace=(await request('/v1/state')).workspaces.find(w=>w.projectId===project.id);
  for(const provider of ['claude','codex'])for(const count of [10,20,32])await t.test(`${provider} ${count}`,async()=>{
   const began=performance.now();let subscription=await stream();const terminals=await Promise.all(Array.from({length:count},()=>command({type:'terminal.open',workspaceId:workspace.id,provider})));
   const ids=new Set(terminals.map(v=>v.id));assert.equal(ids.size,count);
   await until(async()=>{const s=await request('/v1/agents');return s.agents.filter(a=>ids.has(a.terminalId)&&a.provider===provider).length===count;},'all provider registrations');
   await until(async()=>{const s=await request('/v1/state');return s.terminals.filter(v=>ids.has(v.id)&&v.status==='running').length===count;},'simultaneous active sessions');
   await until(async()=>{const all=await Promise.all(terminals.map(v=>output(v.id)));return all.every(o=>text(o).includes(`FIXTURE_READY:${provider}`));},'all provider CLI ready');
   await until(()=>terminals.every(v=>subscription.events.some(e=>e.type==='changed'&&e.terminals?.includes(v.id))),'output availability events');
   const clients=new Map(terminals.map(v=>[v.id,randomUUID()]));const input=(v,line)=>command({type:'terminal.input',terminalId:v.id,clientId:clients.get(v.id),data:line+'\n'});
   const workEventStart=subscription.events.length;
   await Promise.all(terminals.map(v=>input(v,'work')));
   await until(async()=>{const s=await request('/v1/agents');return s.agents.filter(a=>ids.has(a.terminalId)&&a.status==='working').length===count;},'provider turn started');
   await until(()=>terminals.every(v=>subscription.events.slice(workEventStart).some(e=>e.state&&e.agentTerminals?.includes(v.id))),'targeted agent change notifications');
   for(const v of terminals){await until(async()=>text(await output(v.id)).includes('FIXTURE_ACK:work:日本語😀'),'input reached CLI');assert.equal(text(await output(v.id)).split('FIXTURE_ACK:work:日本語😀').length-1,1);}
   // Disconnect the UI event stream while all providers keep running. Cursor replay must
   // recover every output byte produced during that gap, without duplicate instructions.
   const cursors=new Map(await Promise.all(terminals.map(async v=>[v.id,(await output(v.id)).cursor])));
   subscription.ws.terminate();sockets.delete(subscription.ws);
   await Promise.all(terminals.map(v=>input(v,'done')));
   await until(async()=>{const s=await request('/v1/agents');return s.agents.filter(a=>ids.has(a.terminalId)&&a.status==='idle'&&a.lastTurnStatus==='completed').length===count;},'provider completion events');
   subscription=await stream();
   await until(async()=>{const rows=await Promise.all(terminals.map(v=>output(v.id,cursors.get(v.id))));return rows.every(o=>text(o).includes('FIXTURE_ACK:done:日本語😀'));},'reconnect cursor replay');
   for(const v of terminals){const o=await output(v.id,cursors.get(v.id));assert.equal(text(o).split('FIXTURE_ACK:done:日本語😀').length-1,1);assert.equal(text(await output(v.id,o.cursor)),'');}
   const exitEventStart=subscription.events.length;
   await Promise.all(terminals.map(v=>input(v,'exit')));
   await until(async()=>{const s=await request('/v1/state');return s.terminals.filter(v=>ids.has(v.id)&&v.status==='exited'&&v.exitCode===0).length===count;},'provider PTY exit');
   await until(()=>terminals.every(v=>subscription.events.slice(exitEventStart).some(e=>e.type==='changed'&&e.terminals?.includes(v.id))),'exit invalidations');
   assert.ok(subscription.events.some(e=>e.type==='changed'&&e.state));
   subscription.ws.terminate();sockets.delete(subscription.ws);
   const result={provider,count,simultaneousActive:count,milliseconds:Math.round(performance.now()-began),registration:true,input:true,turnEvents:true,exit:true,reconnectCursorReplay:true};evidence.checks.push(result);t.diagnostic(JSON.stringify(result));
  });
  evidence.ok=evidence.checks.length===6;
  assert.ok(evidence.ok,'all six provider/scaling cases must pass');
 }catch(e){failed=true;evidence.error=String(e);throw e;}finally{
  for(const ws of sockets)ws.terminate();
  if(child.exitCode===null&&child.signalCode===null)child.kill('SIGTERM');
  let timer;const result=await Promise.race([ended,new Promise(r=>timer=setTimeout(()=>r(null),15000))]);clearTimeout(timer);
  if(!result){process.kill(-child.pid,'SIGKILL');await ended;failed=true;}
  const processRows=(await readFile(join(home,'fixture-processes.jsonl'),'utf8').catch(()=>'' )).trim().split('\n').filter(Boolean).map(JSON.parse);
  const alive=processRows.filter(({pid})=>{try{process.kill(pid,0);return true;}catch(e){if(e.code==='ESRCH')return false;throw e;}});
  evidence.processesStarted=processRows.length;evidence.processesRemaining=alive.length;
  evidence.shutdown=result;evidence.ok&&=result?.code===0&&alive.length===0;
  if(alive.length)failed=true;await writeFile(join(root,'evidence.json'),JSON.stringify(evidence,null,2));
  console.error(`Provider daemon evidence: ${join(root,'evidence.json')}`);
  if(!failed&&evidence.ok&&process.env.NEURA_KEEP_FIXTURES!=='1')await rm(root,{recursive:true,force:true});
  assert.equal(alive.length,0,'fake provider processes must all be reaped');
  assert.ok(result,'native shutdown deadline');assert.equal(result.code,0,logs);
 }
});
