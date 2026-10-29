import {test} from 'node:test';
import assert from 'node:assert/strict';
import {spawn,execFile} from 'node:child_process';
import {promisify} from 'node:util';
import {mkdtemp,mkdir,writeFile,readFile,realpath,stat,symlink,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join,resolve} from 'node:path';
import {createServer} from 'node:net';
import {request as httpRequest} from 'node:http';
import WebSocket from 'ws';
import {randomUUID} from 'node:crypto';
import {setTimeout as sleep} from 'node:timers/promises';
const exec=promisify(execFile);
const binary=resolve(process.env.NEURA_NATIVE_DAEMON??'crates/native-core/target/debug/neura-native-core');
async function fixture(){
 const root=await realpath(await mkdtemp(join(tmpdir(),'neura-native-protocol-'))),data=join(root,'data'),repo=join(root,'repo');await mkdir(repo);
 const git=(args)=>exec('/usr/bin/git',['-c','core.hooksPath=/dev/null','-c','commit.gpgsign=false',...args],{cwd:repo,env:{...process.env,GIT_CONFIG_GLOBAL:'/dev/null',GIT_CONFIG_NOSYSTEM:'1'}});
 await git(['init','-b','main']);await git(['config','user.name','Native Test']);await git(['config','user.email','test@example.invalid']);await git(['config','core.hooksPath','/dev/null']);await git(['config','commit.gpgsign','false']);await writeFile(join(repo,'hello.txt'),'hello\n');await git(['add','.']);await git(['commit','-m','fixture']);
 const listener=createServer();await new Promise((r,j)=>{listener.once('error',j);listener.listen(0,'127.0.0.1',r)});const port=listener.address().port;await new Promise(r=>listener.close(r));const base=`http://127.0.0.1:${port}`;
 let child,exit,token,logs='',failure=false;
 const request=async(path,{body,headers={},auth=true}={})=>{const send=init=>headers.host?new Promise((resolve,reject)=>{const req=httpRequest(base+path,init,res=>{const chunks=[];res.on('data',b=>chunks.push(b));res.on('error',reject);res.on('end',()=>resolve({status:res.statusCode,headers:new Headers(res.headers),text:async()=>Buffer.concat(chunks).toString()}));});req.on('error',reject);req.end(init.body);}):fetch(base+path,init);const response=await send({method:body===undefined?'GET':'POST',headers:{...(auth?{authorization:`Bearer ${token}`}:{}) ,'content-type':'application/json',...headers},body:body===undefined?undefined:JSON.stringify(body),signal:AbortSignal.timeout(15000)});const text=await response.text();let value;try{value=JSON.parse(text)}catch{value={unparsed:text.slice(0,300)}}return {status:response.status,value,headers:response.headers};};
 const command=(command,operationId=randomUUID())=>request('/v1/commands',{body:{operationId,command}});
 const start=async()=>{logs='';child=spawn(binary,[],{cwd:root,env:{...process.env,NEURA_DEV_DATA_DIR:data,NEURA_DEV_PORT:String(port)},stdio:['ignore','pipe','pipe'],detached:true});child.stdout.on('data',b=>logs=(logs+b).slice(-8000));child.stderr.on('data',b=>logs=(logs+b).slice(-8000));exit=new Promise(r=>child.once('exit',(code,signal)=>r({code,signal})));let spawnError;child.once('error',e=>spawnError=e);for(let i=0;i<200;i++){if(spawnError)throw spawnError;if(child.exitCode!==null)throw Error(`Daemon exited ${logs}`);try{token=(await readFile(join(data,'daemon-token'),'utf8')).trim();const r=await request('/v1/state');if(r.status===200)return;}catch{}await sleep(50);}throw Error('Daemon startup timed out');};
 const stop=async()=>{if(!child||child.exitCode!==null||child.signalCode!==null)return;child.kill('SIGTERM');let timer;const ended=await Promise.race([exit,new Promise(r=>timer=setTimeout(()=>r(null),10000))]);clearTimeout(timer);if(!ended){process.kill(-child.pid,'SIGKILL');await exit;throw Error('Daemon shutdown timed out');}assert.equal(ended.code,0,logs);};
 try{await start();}catch(e){failure=true;try{await stop();}catch{}throw e;}
 return {root,data,repo,git,request,command,start,stop,async crash(){child.kill("SIGKILL");await exit;},stream(){return new WebSocket(base.replace('http:','ws:')+'/v1/stream',{headers:{authorization:`Bearer ${token}`}});},async crash(){child.kill('SIGKILL');await exit;},async close(error){failure||=Boolean(error);try{await stop();}finally{if(failure)console.error(`Native fixture retained: ${root}`);else await rm(root,{recursive:true,force:true});}}};
}
async function success(promise){const r=await promise;assert.equal(r.status,200,JSON.stringify(r.value));return r.value;}
async function eventually(check){for(let i=0;i<100;i++){if(await check())return;await sleep(30);}assert.fail('Expected state did not arrive');}

test('native PTY crash supervisor stops detached writers before replacement health',{timeout:45000},async()=>{
 const f=await fixture();let failure;
 const alive=pid=>{try{process.kill(pid,0);return true;}catch(e){if(e.code==='ESRCH')return false;throw e;}};
 try{
  const initial=await success(f.request('/v1/state'));assert.equal(initial.runtime,'rust');
  const project=await success(f.command({type:'project.add',path:f.repo}));const state=await success(f.request('/v1/state'));const w=state.workspaces.find(v=>v.projectId===project.id);
  const script=join(f.root,'detached.py'),pids=join(f.root,'detached.pid'),writes=join(f.root,'writes');
  await writeFile(script,`import os,signal,time
if os.fork(): os._exit(0)
os.setsid()
if os.fork(): os._exit(0)
signal.signal(signal.SIGHUP,signal.SIG_IGN)
signal.signal(signal.SIGTERM,signal.SIG_IGN)
open(${JSON.stringify(pids)},'w').write(str(os.getpid()))
while True:
 with open(${JSON.stringify(writes)},'a') as f: f.write('x')
 time.sleep(.02)
`);
  const t=await success(f.command({type:'terminal.open',workspaceId:w.id,provider:'shell'}));
  await success(f.command({type:'terminal.input',terminalId:t.id,clientId:randomUUID(),data:`/usr/bin/python3 '${script}'\n`}));
  let pid;await eventually(async()=>{try{pid=Number(await readFile(pids,'utf8'));return pid>1&&alive(pid);}catch{return false;}});
  await f.crash();await f.start();const replacement=await success(f.request('/v1/state'));assert.notEqual(replacement.daemonInstanceId,initial.daemonInstanceId);assert.equal(replacement.runtime,'rust');assert.equal(alive(pid),false,'old detached writer must be gone before new health');
  const bytes=(await stat(writes)).size;await sleep(100);assert.equal((await stat(writes)).size,bytes);assert.equal(replacement.terminals.find(v=>v.id===t.id).status,'interrupted');
 }catch(e){failure=e;throw e;}finally{await f.close(failure);}
});
