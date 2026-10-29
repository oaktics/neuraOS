import {test} from 'node:test';
import assert from 'node:assert/strict';
import {spawn,execFile} from 'node:child_process';
import {promisify} from 'node:util';
import {mkdtemp,mkdir,writeFile,readFile,realpath,stat,symlink,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join,resolve} from 'node:path';
import {createServer} from 'node:net';
import {request as httpRequest} from 'node:http';
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
 const stop=async()=>{if(!child||child.exitCode!==null)return;child.kill('SIGTERM');let timer;const ended=await Promise.race([exit,new Promise(r=>timer=setTimeout(()=>r(null),10000))]);clearTimeout(timer);if(!ended){process.kill(-child.pid,'SIGKILL');await exit;throw Error('Daemon shutdown timed out');}assert.equal(ended.code,0,logs);};
 try{await start();}catch(e){failure=true;try{await stop();}catch{}throw e;}
 return {root,data,repo,git,request,command,start,stop,async close(error){failure||=Boolean(error);try{await stop();}finally{if(failure)console.error(`Native fixture retained: ${root}`);else await rm(root,{recursive:true,force:true});}}};
}
async function success(promise){const r=await promise;assert.equal(r.status,200,JSON.stringify(r.value));return r.value;}
async function eventually(check){for(let i=0;i<100;i++){if(await check())return;await sleep(30);}assert.fail('Expected state did not arrive');}

test('native daemon preserves authenticated commands, idempotency, file boundaries, PTY and restart',{timeout:60000},async()=>{
 const f=await fixture();let failure;
 try{
  assert.equal((await f.request('/v1/state',{auth:false})).status,401);
  assert.equal((await f.request('/v1/state',{headers:{origin:'https://evil.invalid'}})).status,401);
  assert.equal((await f.request('/v1/state',{headers:{host:'evil.invalid'}})).status,401);
  assert.equal((await stat(join(f.data,'daemon-token'))).mode&0o777,0o600);
  assert.equal((await f.request('/v1/state')).headers.get('cache-control'),'no-store');
  assert.equal((await f.command({type:'terminal.open',workspaceId:'invalid'})).status,400);
  const project=await success(f.command({type:'project.add',path:f.repo}));assert.ok(project.id);
  const op=randomUUID(),c={type:'workspace.create',projectId:project.id,baseRef:'HEAD',skipStartup:true};
  const [a,b]=await Promise.all([success(f.command(c,op)),success(f.command(c,op))]);assert.equal(a.id,b.id);assert.notEqual(a.path,f.repo);
  assert.equal((await f.command({...c,name:'different'},op)).status,409);
  const file=await success(f.request(`/v1/workspaces/${a.id}/file?path=hello.txt`));
  await success(f.command({type:'file.save',workspaceId:a.id,path:'hello.txt',content:'編集済み\n',expectedHash:file.hash}));assert.equal(await readFile(join(f.repo,'hello.txt'),'utf8'),'hello\n');
  assert.equal((await f.command({type:'file.save',workspaceId:a.id,path:'hello.txt',content:'stale',expectedHash:file.hash})).status,409);
  await symlink(f.root,join(a.path,'escape'));assert.equal((await f.request(`/v1/workspaces/${a.id}/files?path=escape`)).status,400);
  assert.equal((await f.request(`/v1/workspaces/${a.id}/file?path=..%2Fdata%2Fdaemon-token`)).status,400);
  assert.equal((await f.request(`/v1/workspaces/${a.id}/file?path=.git`)).status,400);
  const openId=randomUUID(),open={type:'terminal.open',workspaceId:a.id,provider:'shell'};
  const terminal=await success(f.command(open,openId));assert.equal((await success(f.command(open,openId))).id,terminal.id);
  const clientId=randomUUID(),inputId=randomUUID();const input={type:'terminal.input',terminalId:terminal.id,clientId,data:"printf 'persistent-output\\n'; printf x >> once.txt\n"};
  await success(f.command(input,inputId));await success(f.command(input,inputId));assert.equal((await f.command({...input,clientId:randomUUID()})).status,409);
  await eventually(async()=>readFile(join(a.path,'once.txt'),'utf8').then(s=>s==='x',()=>false));
  const output=await success(f.request(`/v1/terminals/${terminal.id}/output?after=0`));assert.match(output.data,/persistent-output/);
  const compact=await success(f.request(`/v1/terminals/${terminal.id}/output?after=0&chunksOnly=true`));assert.equal(compact.data,'');assert.match(compact.chunks.map(c=>c.data).join(''),/persistent-output/);
  await success(f.command({type:'terminal.stop',terminalId:terminal.id}));
  await eventually(async()=>{const s=await success(f.request('/v1/state'));return s.terminals.find(t=>t.id===terminal.id)?.status!=='running';});
  const stopped=await f.command({type:'terminal.input',terminalId:terminal.id,clientId,data:'do not send'});assert.ok([404,409].includes(stopped.status));
  const token=await readFile(join(f.data,'daemon-token'),'utf8');await f.stop();await f.start();assert.equal(await readFile(join(f.data,'daemon-token'),'utf8'),token);
  const restored=await success(f.request('/v1/state'));assert.ok(restored.features.includes('state.stream'));assert.ok(restored.workspaces.some(w=>w.id===a.id));assert.match((await success(f.request(`/v1/terminals/${terminal.id}/output?after=0`))).data,/persistent-output/);
  assert.equal((await success(f.command(c,op))).id,a.id);
 }catch(e){failure=e;throw e;}finally{await f.close(failure);}
});

test('native daemon keeps ordinary folders and folderless projects distinct',{timeout:30000},async()=>{
 const f=await fixture();let failure;
 try{
  const folder=join(f.root,'documents');await mkdir(folder);await writeFile(join(folder,'notes.txt'),'notes\n');
  const project=await success(f.command({type:'project.add',path:folder}));assert.equal(project.isGit,false);
  const state=await success(f.request('/v1/state'));const workspace=state.workspaces.find(w=>w.projectId===project.id);assert.equal(workspace.kind,'folder');
  assert.equal((await f.command({type:'workspace.create',projectId:project.id,baseRef:'HEAD'})).value.error,'git_required');
  assert.equal((await f.request(`/v1/workspaces/${workspace.id}/git`)).value.error,'git_required');
  assert.equal((await success(f.command({type:'project.add',path:folder}))).id,project.id);
  const scratch=await success(f.command({type:'project.create',name:'No folder'}));assert.equal(scratch.folderless,true);
  const latest=await success(f.request('/v1/state'));const free=latest.workspaces.find(w=>w.projectId===scratch.id);assert.equal(free.kind,'scratch');
  assert.equal((await f.request(`/v1/workspaces/${free.id}/files`)).value.error,'folder_required');
 }catch(e){failure=e;throw e;}finally{await f.close(failure);}
});
