// Interactive acceptance runner. Click the named extension in the probe's real
// Chrome toolbar at each prompt. CDP never invokes an action or grants access.
import {execFileSync, spawn} from 'node:child_process';
import {createServer} from 'node:http';
import {mkdtemp, mkdir, readFile, writeFile, rename, rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join, resolve} from 'node:path';
import assert from 'node:assert/strict';
import {prepareChromium, cefRoot} from './prepare.mjs';
import {bundleChromium} from './bundle.mjs';
import {signApplication} from '../signing/sign.mjs';
const root=resolve(import.meta.dirname,'../../..');
const data=await mkdtemp(join(tmpdir(),'neura-tab-context-'));
const app=join(data,'TabContext.app'), profile=join(data,'profile');
await mkdir(join(app,'Contents/MacOS'),{recursive:true});
await mkdir(join(app,'Contents/Resources/Licenses'),{recursive:true});
await mkdir(profile);
await prepareChromium();
execFileSync('xcrun',['clang++','-std=c++20','-fobjc-arc','-Werror','-mmacosx-version-min=14.0','-I',join(cefRoot,'sdk'),'-I',join(root,'apps/macos/Sources/ChromiumBridge/include'),join(import.meta.dirname,'tab-context-probe.mm'),'-framework','AppKit','-o',join(app,'Contents/MacOS/NeuraOS')],{stdio:'inherit'});
const id='com.neuraos.extensions-test.tab-context.'+data.split('-').at(-1).toLowerCase();
await writeFile(join(app,'Contents/Info.plist'),`<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>${id}</string><key>CFBundleExecutable</key><string>NeuraOS</string><key>CFBundleName</key><string>Tab Context Probe</string><key>CFBundlePackageType</key><string>APPL</string><key>NSHighResolutionCapable</key><true/></dict></plist>`);
await bundleChromium(app,id); signApplication(app,'-');
const server=createServer((req,res)=>{res.setHeader('Content-Type','text/html');res.end(`<title>Context ${req.url}</title><h1>Tab ${req.url}</h1><input id="draft" placeholder="Unsaved draft">`);});
await new Promise(r=>server.listen(0,'127.0.0.1',r));
const base=`http://127.0.0.1:${server.address().port}`;
const reservation=createServer();await new Promise(r=>reservation.listen(0,'127.0.0.1',r));const port=reservation.address().port;await new Promise(r=>reservation.close(r));
const child=spawn(join(app,'Contents/MacOS/NeuraOS'),[profile,base,String(port)],{stdio:['ignore','ignore','pipe']});
let stderr='',finished=false;child.stderr.on('data',b=>{stderr+=b;});
const exited=new Promise((resolve,reject)=>{child.once('error',reject);child.once('exit',(code,signal)=>{finished=true;resolve({code,signal});});});
const lifecycleOnly=process.argv.includes("--lifecycle-only");
const clients=[];const evidence={profile,base,lifecycleOnly,checks:[]};
const sleep=ms=>new Promise(r=>setTimeout(r,ms));
async function until(fn,label,timeout=30000){let last;const end=Date.now()+timeout;while(Date.now()<end){if(finished)throw Error(`Probe exited: ${stderr}`);try{const value=await fn();if(value)return value;}catch(e){last=e;}await sleep(100);}throw Error(`Timed out: ${label}: ${last??''}`);}
async function connect(address){
 const ws=new WebSocket(address);await new Promise((r,j)=>{ws.onopen=r;ws.onerror=j;});let id=0;const pending=new Map();
 ws.onmessage=e=>{const m=JSON.parse(e.data),p=pending.get(m.id);if(!p)return;pending.delete(m.id);clearTimeout(p.timer);m.error?p.reject(Error(JSON.stringify(m.error))):p.resolve(m.result);};
 ws.onclose=()=>{for(const p of pending.values()){clearTimeout(p.timer);p.reject(Error('CDP closed'));}pending.clear();};
 const client={call(method,params={}){return new Promise((resolve,reject)=>{const n=++id;const timer=setTimeout(()=>{pending.delete(n);reject(Error(`CDP timeout: ${method}`));},10000);pending.set(n,{resolve,reject,timer});ws.send(JSON.stringify({id:n,method,params}));});},close(){ws.close();}};clients.push(client);return client;
}
async function evaluate(client,expression){const r=await client.call('Runtime.evaluate',{expression,awaitPromise:true,returnByValue:true});assert(!r.exceptionDetails,JSON.stringify(r));return r.result.value;}
const targets=()=>fetch(`http://127.0.0.1:${port}/json/list`).then(r=>r.json());
async function command(value){await rm(join(profile,'state.json'),{force:true});await writeFile(join(profile,'command.tmp'),JSON.stringify(value));await rename(join(profile,'command.tmp'),join(profile,'command.json'));return until(async()=>JSON.parse(await readFile(join(profile,'state.json'),'utf8')),'native state');}
try {
 const version=await until(()=>fetch(`http://127.0.0.1:${port}/json/version`).then(r=>r.json()),'CDP');
 await until(()=>stderr.includes(version.webSocketDebuggerUrl),'owned process endpoint');evidence.version=version.Browser;
 const browser=await connect(version.webSocketDebuggerUrl);
 const extensionId=(await browser.call('Extensions.loadUnpacked',{path:join(root,'tests/fixtures/chromium-tab-context')})).id;
 const workerTarget=await until(async()=>(await targets()).find(t=>t.url===`chrome-extension://${extensionId}/worker.js`),'worker');
 const worker=await connect(workerTarget.webSocketDebuggerUrl);await worker.call('Runtime.enable');
 const tabs=await until(async()=>{const tabs=await evaluate(worker,`chrome.tabs.query({url:${JSON.stringify(base+'/*')}})`);return tabs.length===2?tabs:null;},'Chrome tabs');
 tabs.sort((a,b)=>a.url.localeCompare(b.url));evidence.tabs=tabs;
 for(const tab of tabs){assert(tab.windowId>=0);const denied=await evaluate(worker,`probeTab(${tab.id})`);assert(denied.error);evidence.checks.push({name:'before-click-denied',url:tab.url,...denied});}
 const pages=[];
 for(const tab of tabs){const target=await until(async()=>(await targets()).find(t=>t.url===tab.url),'page');const page=await connect(target.webSocketDebuggerUrl);pages.push(page);await evaluate(page,'document.querySelector("#draft").value="draft-"+location.pathname');}
 console.log(`PROBE ${JSON.stringify({data,profile,app,bundleId:id,port,base,extensionId})}`);
 if(!lifecycleOnly) {
 console.log('CLICK 1: Open Extensions > neuraOS Tab Context Probe on Tab 1.');
 const first=await until(async()=>{const s=await evaluate(worker,'chrome.storage.local.get("popup")');return s.popup;},'real popup action',180000);
 assert.equal(first.tab.id,tabs[0].id);assert.equal(first.execution.url,tabs[0].url);assert.equal(first.execution.draft,'draft-/0');assert(first.contexts.some(c=>c.contextType==='POPUP'));evidence.checks.push({name:'popup-action',result:first});
 const otherDenied=await evaluate(worker,`probeTab(${tabs[1].id})`);assert(otherDenied.error);evidence.checks.push({name:'other-tab-denied',...otherDenied});
 // Change runtime action metadata through the fixture's normal API.
 await evaluate(worker,'chrome.action.setPopup({popup:""})');
 const switched=await command({select:1,resize:true});assert(switched.states.every(s=>s.mappedOwner));assert(!switched.states[0].visible);assert(switched.states[1].visible);assert.equal(switched.states[1].frame,switched.states[1].expected);evidence.checks.push({name:'switch-move-resize',...switched});
 console.log('CLICK 2: Open Extensions > neuraOS Tab Context Probe on Tab 2 (onClicked, no popup).');
 const second=await until(async()=>{const s=await evaluate(worker,'chrome.storage.local.get("clicked")');return s.clicked;},'real onClicked action',180000);
 assert.equal(second.tab.id,tabs[1].id);assert.equal(second.result.url,tabs[1].url);assert.equal(second.result.draft,'draft-/1');evidence.checks.push({name:'no-popup-action',result:second});
 }
 if(lifecycleOnly) {
 const switched=await command({select:1,resize:true});assert(switched.states.every(s=>s.mappedOwner));assert(!switched.states[0].visible);assert(switched.states[1].visible);assert.equal(switched.states[1].frame,switched.states[1].expected);evidence.checks.push({name:'switch-move-resize',...switched});
 }
 for(let i=0;i<2;i++){const state=await evaluate(pages[i],'({draft:document.querySelector("#draft").value,actions:Number(document.body.dataset.contextActions??0)})');assert.equal(state.draft,`draft-/${i}`);assert.equal(state.actions,lifecycleOnly?0:1);evidence.checks.push({name:'same-document-preserved',tab:i,...state});}
 await pages[1].call('Page.navigate',{url:base.replace('127.0.0.1','localhost')+'/revoked'});
 await until(async()=>await evaluate(pages[1],'location.hostname')==='localhost','cross-origin navigation');
 const revoked=await evaluate(worker,`probeTab(${tabs[1].id})`);assert(revoked.error);evidence.checks.push({name:lifecycleOnly?'cross-origin-denied':'cross-origin-grant-revoked',...revoked});
 await pages[0].call('Runtime.evaluate',{expression:'window.open("/popup")',userGesture:true});
 const popupTarget=await until(async()=>(await targets()).find(t=>t.url===base+'/popup'),'window.open target');
 const popupPage=await connect(popupTarget.webSocketDebuggerUrl);
 await until(async()=>await evaluate(popupPage,'document.readyState')==='complete','popup loaded');
 assert.equal(await evaluate(popupPage,'opener.document.querySelector("#draft").value'),'draft-/0');
 const popupTabs=await evaluate(worker,`chrome.tabs.query({url:${JSON.stringify(base+'/popup')}})`);assert.equal(popupTabs.length,1);assert(popupTabs[0].windowId>=0);
 const popupState=await command({select:2});assert.equal(popupState.states.length,3);assert(popupState.states[2].visible);assert(popupState.states[2].mappedOwner);
 await command({closePopup:true});evidence.checks.push({name:'window-open-context-and-opener',tab:popupTabs[0],state:popupState});
 await command({sheet:true});await sleep(500);const sheet=await command({});assert(sheet.states.every(s=>!s.visible));
 await command({dismissSheet:true});await sleep(500);const restored=await command({});assert(restored.states[1].visible);assert(!restored.states[0].visible);evidence.checks.push({name:'native-sheet-isolation',sheet,restored});
} finally {
 clients.forEach(c=>c.close());await writeFile(join(profile,'stop'),'stop');
 const timeout=setTimeout(()=>child.kill('SIGKILL'),15000);const exit=await exited;clearTimeout(timeout);evidence.exit=exit;
 evidence.shutdown=await readFile(join(profile,'shutdown.txt'),'utf8').catch(()=>null);
 await writeFile(join(data,'evidence.json'),JSON.stringify(evidence,null,2));await writeFile(join(data,'stderr.log'),stderr);
 server.closeAllConnections();server.close();
 assert.equal(exit.code,0,'clean process exit');assert.equal(evidence.shutdown,'completed','CEF shutdown barrier');
 console.log(`Evidence: ${join(data,'evidence.json')}`);
}
console.log(lifecycleOnly?'PASS: lifecycle only (no extension action click/grant claim).':'PASS: real popup/onClicked, per-tab activeTab, navigation revocation, draft preservation, resize, sheets, clean shutdown.');
