import {createServer} from 'node:http';
import {spawn} from 'node:child_process';
import {mkdtemp,writeFile,rm,mkdir,chmod} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {resolve,join} from 'node:path';
import assert from 'node:assert/strict';
const data=process.env.NEURA_EXTENSION_TEST_DATA??await mkdtemp(join(tmpdir(),'neura-extensions-smoke-'));
await mkdir(data,{recursive:true});
const port=Number(process.env.NEURA_EXTENSION_TEST_PORT??44331);
const server=createServer((req,res)=>{res.setHeader('Content-Type','text/html');res.end('<!doctype html><h1>Waiting for extension</h1><form><label>Username <input name="username" autocomplete="username"></label><label>Password <input type="password" name="password" autocomplete="current-password"></label><button type="button">Test sign in</button></form>');});
await new Promise(r=>server.listen(0,'127.0.0.1',r));
const url=`http://127.0.0.1:${server.address().port}/`;
const executable=resolve(process.env.NEURA_APP_OUTPUT??'apps/macos/dist/neuraOS.app','Contents/MacOS/NeuraOS');
const sleep=ms=>new Promise(r=>setTimeout(r,ms));
async function until(fn){for(let i=0;i<900;i++){try{const v=await fn();if(v)return v;}catch{}await sleep(100);}throw Error('Timed out');}
async function connect(address){
 const ws=new WebSocket(address);await new Promise((r,j)=>{ws.onopen=r;ws.onerror=j;});let id=0;const pending=new Map();
 ws.onclose=()=>{for(const p of pending.values()){clearTimeout(p.timer);p.reject(Error('CDP disconnected'));}pending.clear();};
 ws.onmessage=e=>{const m=JSON.parse(e.data);if(m.id){const p=pending.get(m.id);pending.delete(m.id);clearTimeout(p.timer);m.error?p.reject(Error(JSON.stringify(m.error))):p.resolve(m.result);}};
 return {call(method,params={}){return new Promise((resolve,reject)=>{const n=++id;const timer=setTimeout(()=>{pending.delete(n);reject(Error('CDP timeout: '+method));},15000);pending.set(n,{resolve,reject,timer});ws.send(JSON.stringify({id:n,method,params}));});},close(){ws.close();}};
}
const evidence=[];let extensionId, previous=0;
try {
 for(let phase=0;phase<2;phase++){
  await rm(join(data,'stop'),{force:true});
  const child=spawn(executable,['--extensions-smoke',url,data,String(port)],{stdio:['ignore','inherit','inherit']});
  let childFinished=false;child.once('exit',()=>{childFinished=true;});
  const exited=new Promise((r,j)=>{child.once('error',j);child.once('exit',code=>r(code));});
  const timeout=setTimeout(()=>child.kill('SIGKILL'),900000);
  const clients=[];
  try{
   const version=await until(()=>fetch(`http://127.0.0.1:${port}/json/version`).then(r=>r.json()));
   const browser=await connect(version.webSocketDebuggerUrl);clients.push(browser);
   if(phase===0){
    const targets=await until(()=>fetch(`http://127.0.0.1:${port}/json/list`).then(r=>r.json()));
    const manager=await connect(targets.find(t=>t.url==='chrome://extensions/').webSocketDebuggerUrl);clients.push(manager);
    await manager.call('Runtime.evaluate',{expression:'chrome.developerPrivate.updateProfileConfiguration({inDeveloperMode:true})',awaitPromise:true});
    const existing=await browser.call('Extensions.getExtensions');
    let sample=existing.extensions.find(e=>e.path===resolve('tests/fixtures/chromium-extension'));
    if(!sample){
     console.log('Select this fixture in the native Load unpacked chooser:',resolve('tests/fixtures/chromium-extension'));
     await manager.call('Runtime.evaluate',{expression:'chrome.developerPrivate.loadUnpacked({failQuietly:true})',userGesture:true});
     sample=await until(async()=>{const r=await browser.call('Extensions.getExtensions');return r.extensions.find(e=>e.path===resolve('tests/fixtures/chromium-extension'));});
    }
    extensionId=sample.id;
    await manager.call('Runtime.evaluate',{expression:`chrome.developerPrivate.reload(${JSON.stringify(extensionId)},{failQuietly:true})`,awaitPromise:true});
   }
   const installed=await until(async()=>{const state=await browser.call('Extensions.getExtensions');return state.extensions.some(e=>e.id===extensionId&&e.enabled)?state:null;});
   const targets=await until(()=>fetch(`http://127.0.0.1:${port}/json/list`).then(r=>r.json()));
   const embedded=targets.find(t=>t.url===url);assert(embedded);
   const tab=await connect(embedded.webSocketDebuggerUrl);clients.push(tab);
   await tab.call('Page.reload');
   const state=await until(async()=>{const r=await tab.call('Runtime.evaluate',{expression:'Number(document.body.dataset.extensionVisits)',returnByValue:true});return r.result.value>previous?r.result.value:0;});
   previous=state;console.log('Content/worker/storage passed',state);
   const host=join(data,'native-host.py');
   await writeFile(host,`#!/usr/bin/python3
import sys,struct,json
n=struct.unpack('<I',sys.stdin.buffer.read(4))[0]
message=json.loads(sys.stdin.buffer.read(n))
reply=json.dumps({'echo':message['probe']}).encode()
sys.stdout.buffer.write(struct.pack('<I',len(reply))+reply)
sys.stdout.buffer.flush()
`);
   await chmod(host,0o700);
   const hosts=join(data,'Chromium/NativeMessagingHosts');await mkdir(hosts,{recursive:true});
   await writeFile(join(hosts,'com.neuraos.extension_smoke.json'),JSON.stringify({name:'com.neuraos.extension_smoke',description:'Disposable native messaging test',path:host,type:'stdio',allowed_origins:[`chrome-extension://${extensionId}/`]}));
   console.log('Native host registered');
   const workerTarget=await until(async()=>{const ts=await fetch(`http://127.0.0.1:${port}/json/list`).then(r=>r.json());return ts.find(t=>t.type==='service_worker'&&t.url===`chrome-extension://${extensionId}/worker.js`);});
   const worker=await connect(workerTarget.webSocketDebuggerUrl);clients.push(worker);
   const native=await worker.call('Runtime.evaluate',{expression:`chrome.runtime.sendNativeMessage('com.neuraos.extension_smoke',{probe:'native-message-passed'})`,awaitPromise:true,returnByValue:true});
   assert.equal(native.result.value?.echo,'native-message-passed',JSON.stringify(native));
   evidence.push({phase,extensionId,installed,embeddedContentWorkerStorageVisits:state,nativeMessaging:native.result.value});
   console.log(JSON.stringify(evidence.at(-1)));
   if(process.env.NEURA_EXTENSION_TEST_HOLD==='1'){
    console.log(`UI inspection ready; profile=${data}, port=${port}`);
    while (!(await import('node:fs')).existsSync(join(data,'continue')) && !childFinished) await sleep(500);
    assert(!childFinished,'fixture exited during UI inspection');
    await rm(join(data,'continue'),{force:true});
   }
  }finally{
   clients.forEach(c=>c.close());await writeFile(join(data,'stop'),'stop');
   const closeTimeout=setTimeout(()=>child.kill('SIGKILL'),15000);
   const code=await exited;clearTimeout(closeTimeout);clearTimeout(timeout);assert.equal(code,0,'clean CEF shutdown');
  }
 }
 await writeFile(join(data,'evidence.json'),JSON.stringify(evidence,null,2));
 console.log(`Extension MV3 load, embedded execution, worker/storage, clean restart passed. Evidence: ${data}`);
}finally{server.closeAllConnections();server.close();}
