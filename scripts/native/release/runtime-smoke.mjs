import {mkdtemp,cp,rm,readFile} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join,resolve} from 'node:path';
import {fileURLToPath} from 'node:url';
import {spawn} from 'node:child_process';
import {createServer} from 'node:net';
import {randomUUID} from 'node:crypto';
import assert from 'node:assert/strict';
import {assertNativeRuntime} from './native-runtime.mjs';
export async function smokeRuntime(original){
 await assertNativeRuntime(original);
 const temporary=await mkdtemp(join(tmpdir(),'neura-runtime-'));
 let child,exited,logs='';
 const sleep=ms=>new Promise(r=>setTimeout(r,ms));
 const stop=async()=>{
  if(!child||child.exitCode!==null||child.signalCode!==null)return;
  child.kill('SIGTERM');let timer;
  const result=await Promise.race([exited,new Promise(r=>timer=setTimeout(()=>r(null),10000))]);clearTimeout(timer);
  if(!result){child.kill('SIGKILL');await exited;throw Error('Native daemon shutdown timed out');}
  assert.equal(result.code,0,logs);
 };
 try{
  const runtime=join(temporary,'Runtime');await cp(original,runtime,{recursive:true,verbatimSymlinks:true});
  await assertNativeRuntime(runtime);
  const listener=createServer();await new Promise(r=>listener.listen(0,'127.0.0.1',r));const port=listener.address().port;await new Promise(r=>listener.close(r));
  const data=join(temporary,'data'),endpoint=`http://127.0.0.1:${port}`;
  let token;
  const request=async(path,command)=>{
   const response=await fetch(endpoint+path,{method:command?'POST':'GET',headers:{authorization:`Bearer ${token}`,'content-type':'application/json'},...(command?{body:JSON.stringify({operationId:randomUUID(),command})}:{}),signal:AbortSignal.timeout(5000)});
   assert.equal(response.status,200,`${path}: ${await response.clone().text()}`);return response.json();
  };
  const start=async()=>{
   const env={...process.env,NEURA_DEV_DATA_DIR:data,NEURA_DEV_PORT:String(port),PATH:'/usr/bin:/bin:/usr/sbin:/sbin'};
   delete env.NODE_PATH;delete env.NODE_OPTIONS;
   child=spawn(join(runtime,'bin/neura-native-core'),[],{cwd:temporary,env,stdio:['ignore','pipe','pipe']});
   let spawnError;child.once('error',e=>{spawnError=e;});exited=new Promise(r=>child.once('exit',(code,signal)=>r({code,signal})));
   child.stdout.on('data',b=>logs=(logs+b).slice(-8000));child.stderr.on('data',b=>logs=(logs+b).slice(-8000));
   for(let i=0;i<150;i++){
    if(spawnError)throw spawnError;if(child.exitCode!==null)throw Error(`Native daemon exited: ${logs}`);
    try{token=(await readFile(join(data,'daemon-token'),'utf8')).trim();return await request('/v1/state');}catch{}
    await sleep(100);
   }
   throw Error('Relocated native daemon startup timed out');
  };
  await start();
  const project=await request('/v1/commands',{type:'project.create',name:'Relocated runtime smoke'});
  const workspace=(await request('/v1/state')).workspaces.find(w=>w.projectId===project.id);assert(workspace);
  const terminal=await request('/v1/commands',{type:'terminal.open',workspaceId:workspace.id,provider:'shell'});
  await request('/v1/commands',{type:'terminal.input',terminalId:terminal.id,clientId:randomUUID(),data:"printf '\\nneura-native-runtime-ok\\n'\n"});
  let output;
  for(let i=0;i<100;i++){output=await request(`/v1/terminals/${terminal.id}/output?after=0`);if(/\r?\nneura-native-runtime-ok\r?\n/.test(output.data))break;await sleep(100);}
  assert.match(output.data,/\r?\nneura-native-runtime-ok\r?\n/,'Real PTY output must be observed, not just echoed input');
  await stop();
  const restored=await start();assert(restored.workspaces.some(w=>w.id===workspace.id));
  assert.match((await request(`/v1/terminals/${terminal.id}/output?after=0`)).data,/neura-native-runtime-ok/);
  await stop();console.log('Relocated native-only Runtime: authenticated HTTP, SQLite restart persistence, real PTY and clean shutdown passed.');
 }finally{try{await stop();}finally{await rm(temporary,{recursive:true,force:true});}}
}
if(process.argv[1]&&resolve(process.argv[1])===fileURLToPath(import.meta.url))await smokeRuntime(resolve(process.env.NEURA_APP_OUTPUT??'apps/macos/dist/neuraOS.app','Contents/Resources/Runtime'));
