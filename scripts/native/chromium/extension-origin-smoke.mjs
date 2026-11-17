import {createServer} from 'node:http';
import {spawn, execFileSync} from 'node:child_process';
import {mkdtemp, writeFile, readFile, mkdir} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {resolve, join} from 'node:path';
import assert from 'node:assert/strict';

// Diagnostic mode retains evidence even on an unfixed CEF. Default is a gate.
const diagnostic = process.argv.includes('--diagnostic');
const chrome = process.env.NEURA_ORIGIN_CHROME;
assert(chrome, 'Set NEURA_ORIGIN_CHROME to Chrome for Testing/Chromium executable');
const data = await mkdtemp(join(tmpdir(), 'neura-extension-origin-'));
const fixture = resolve('tests/fixtures/chromium-extension-origin');
const captures = [];
const server = createServer((req, res) => {
  const headers = Object.fromEntries(['origin','sec-fetch-site','sec-fetch-mode','sec-fetch-dest'].map(k => [k, req.headers[k] ?? null]));
  const record = {path:req.url, method:req.method, ...headers};
  captures.push(record);
  res.setHeader('Access-Control-Allow-Origin', req.headers.origin ?? '*');
  res.setHeader('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'X-Probe');
  res.setHeader('Content-Type', 'application/json');
  res.end(JSON.stringify(record));
});
await new Promise(r => server.listen(0, '127.0.0.1', r));
const url = `http://127.0.0.1:${server.address().port}`;
const sleep = ms => new Promise(r => setTimeout(r, ms));
async function until(fn) {
  let last;
  const deadline=Date.now()+30000;
  while(Date.now()<deadline) {try {const v=await fn(); if(v)return v;} catch(e){last=e;} await sleep(100);}
  throw Error(`Timed out: ${last ?? ''}`);
}
async function connect(address) {
  const ws = new WebSocket(address); await new Promise((r,j)=>{ws.onopen=r;ws.onerror=j;});
  let id=0; const pending=new Map();
  ws.onmessage=e=>{const m=JSON.parse(e.data);const p=pending.get(m.id);if(!p)return;pending.delete(m.id);clearTimeout(p.timer);m.error?p.reject(Error(JSON.stringify(m.error))):p.resolve(m.result);};
  ws.onclose=()=>{for(const p of pending.values()){clearTimeout(p.timer);p.reject(Error('CDP disconnected'));}pending.clear();};
  return {call(method,params={}){return new Promise((resolve,reject)=>{const n=++id;const timer=setTimeout(()=>{pending.delete(n);reject(Error(`CDP timeout: ${method}`));},15000);pending.set(n,{resolve,reject,timer});ws.send(JSON.stringify({id:n,method,params}));});},close(){ws.close();}};
}
const results=[];
try {
  for(const kind of ['chrome','neuraOS']) {
    const profile=join(data,kind); await mkdir(profile);
    const port=kind==='chrome'?Number(process.env.NEURA_ORIGIN_CHROME_PORT??44337):Number(process.env.NEURA_ORIGIN_CEF_PORT??44338);
    const executable=kind==='chrome'?chrome:resolve(process.env.NEURA_APP_OUTPUT??'apps/macos/dist/neuraOS.app','Contents/MacOS/NeuraOS');
    const args=kind==='chrome'?[`--user-data-dir=${profile}`,`--remote-debugging-port=${port}`,`--load-extension=${fixture}`,'--use-mock-keychain','--no-first-run','--no-default-browser-check','about:blank']:['--extensions-smoke',url,profile,String(port)];
    const child=spawn(executable,args,{stdio:['ignore','ignore','pipe']});
    let stderr='';child.stderr.on('data',b=>{stderr+=b;});
    const exited=new Promise((r,j)=>{child.once('error',j);child.once('exit',(code,signal)=>r({code,signal}));});
    const clients=[];
    try {
      const version=await until(()=>fetch(`http://127.0.0.1:${port}/json/version`).then(r=>r.json()));
      // Never attach to an unrelated browser if the requested port is occupied.
      await until(()=>stderr.includes(version.webSocketDebuggerUrl));
      const browser=await connect(version.webSocketDebuggerUrl);clients.push(browser);
      let id;
      if(kind==='neuraOS') id=(await browser.call('Extensions.loadUnpacked',{path:fixture})).id;
      const targets=()=>fetch(`http://127.0.0.1:${port}/json/list`).then(r=>r.json());
      const workerTarget=await until(async()=>(await targets()).find(t=>t.type==='service_worker'&&t.url.endsWith('/worker.js')));
      id??=new URL(workerTarget.url).host;
      const worker=await connect(workerTarget.webSocketDebuggerUrl);clients.push(worker);
      await worker.call('Runtime.enable');
      await worker.call('Runtime.runIfWaitingForDebugger');
      await until(async()=>{const r=await worker.call('Runtime.evaluate',{expression:'typeof probeOrigin==="function" && chrome.runtime.id',returnByValue:true});return r.result.value===id;});
      const record={kind,version:version.Browser,extensionId:id,probes:[]};results.push(record);
      async function probe(client,context) {
        for(const host of ['granted','ungranted']) for(const method of ['GET','POST']) {
          const endpoint=`${host==='granted'?url:url.replace('127.0.0.1','localhost')}/${context}/${host}/${method}`;
          const r=await client.call('Runtime.evaluate',{expression:`probeOrigin(${JSON.stringify(endpoint)},${JSON.stringify(method)})`,awaitPromise:true,returnByValue:true});
          assert(!r.exceptionDetails,JSON.stringify(r));
          record.probes.push({context,host,...r.result.value});
        }
      }
      await probe(worker,'service_worker');
      if(kind==='neuraOS') await writeFile(join(profile,'open-extension'),id);
      else {
        await until(async()=>{
          execFileSync('open', ['-a', resolve(chrome, '../../..')]);
          const opened=await worker.call('Runtime.evaluate',{expression:'(async()=>{const windows=await chrome.windows.getAll(); const win=windows[0] ?? await chrome.windows.create({url:"about:blank"}); await chrome.windows.update(win.id,{focused:true}); await new Promise(r=>setTimeout(r,500)); await chrome.action.openPopup({windowId:win.id});})()',awaitPromise:true});
          return !opened.exceptionDetails;
        });
      }
      const popupTarget=await until(async()=>(await targets()).find(t=>t.url===`chrome-extension://${id}/popup.html`));
      const popup=await connect(popupTarget.webSocketDebuggerUrl);clients.push(popup);
      await until(async()=>{const r=await popup.call('Runtime.evaluate',{expression:`location.protocol==='chrome-extension:' && chrome.runtime?.id===${JSON.stringify(id)} && document.readyState==='complete' && typeof probeOrigin==='function'`,returnByValue:true});return r.result.value===true;});
      await probe(popup,'popup');
      const {targetId}=await browser.call('Target.createTarget',{url:`chrome-extension://${id}/popup.html?tab`});
      const pageTarget=await until(async()=>(await targets()).find(t=>t.id===targetId));
      const page=await connect(pageTarget.webSocketDebuggerUrl);clients.push(page);
      await until(async()=>{const r=await page.call('Runtime.evaluate',{expression:'typeof probeOrigin==="function" && location.protocol',returnByValue:true});return r.result.value==='chrome-extension:';});
      await probe(page,'tab');
    } finally {
      clients.forEach(c=>c.close());
      if(kind==='neuraOS') await writeFile(join(profile,'stop'),'stop'); else child.kill('SIGTERM');
      const timeout=setTimeout(()=>child.kill('SIGKILL'),15000);
      const exit=await exited;clearTimeout(timeout);
      await writeFile(join(profile,'stderr.log'),stderr);
      if(kind==='neuraOS') assert.equal(exit.code,0,'clean CEF shutdown');
    }
  }
} finally {
  await writeFile(join(data,'evidence.json'),JSON.stringify({results,captures},null,2));
  server.closeAllConnections();server.close();
  console.log(`Origin evidence: ${data}/evidence.json`);
}
for(const r of results) {
  console.log(r.kind,r.version,JSON.stringify(r.probes));
  if(!diagnostic) for(const p of r.probes) {
    // Chromium may omit Origin for a granted GET. POST must preserve the
    // extension origin; ungranted CORS requests must always carry it.
    const expected=`chrome-extension://${r.extensionId}`;
    if(p.method==='POST'||p.host==='ungranted') assert.equal(p.origin,expected,`${r.kind} ${p.context} ${p.host} ${p.method}`);
    else assert(p.origin===null||p.origin===expected,`${r.kind} ${p.context}: invalid GET Origin ${p.origin}`);
  }
}

if(!diagnostic) {
  assert.equal(results.length,2);
  for(const r of results) assert.equal(r.probes.length,12);
  const normalized=r=>r.probes.map(p=>({...p,origin:p.origin?.replace(r.extensionId,'<extension-id>')??null}));
  assert.deepEqual(normalized(results[1]),normalized(results[0]),'CEF Origin and Sec-Fetch metadata must match the comparison Chrome');
}
