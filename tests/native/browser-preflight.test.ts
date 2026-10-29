import {test} from 'node:test';
import assert from 'node:assert/strict';
import {EventEmitter} from 'node:events';
import {validateBrowserConfiguration, browserPreflight, monitorBrowserChild} from '../../scripts/native/chromium/browser-preflight.mjs';
const expected={data:'/tmp/neura-browser-test',endpoint:'http://127.0.0.1:44319'};
const good={CFBundleIdentifier:'com.neuraos.browser-smoke.test',NeuraDataDirectory:expected.data,NeuraEndpoint:expected.endpoint};
test('candidate fields reject mismatch before any child or daemon is started',async()=>{
 validateBrowserConfiguration(good,expected);
 for(const [field,value] of Object.entries({CFBundleIdentifier:'app.neuraos.native',NeuraDataDirectory:'/private/tmp/neura-browser-test',NeuraEndpoint:'http://127.0.0.1:44320'})){
  assert.throws(()=>validateBrowserConfiguration({...good,[field]:value},expected),new RegExp(field));
 }
 await assert.rejects(browserPreflight('/tmp/neura-browser-absent.app',expected),/executable/);
 assert.throws(()=>validateBrowserConfiguration({...good,NeuraEndpoint:'https://user:secret@example.com/?token=SECRET'},expected),e=>!String(e).includes('SECRET')&&!String(e).includes('secret')&&String(e).includes('redacted'));
});
test('early exit immediately interrupts an otherwise pending readiness call',async()=>{
 const child=new EventEmitter();const monitor=monitorBrowserChild(child);
 const waiting=monitor.race(new Promise(()=>{}));child.emit('exit',2,null);
 await assert.rejects(waiting,/code=2 signal=null/);assert.throws(()=>monitor.check(),/exited early/);
 const failed=new EventEmitter();const second=monitorBrowserChild(failed);failed.emit('error',Error('private details'));
 await assert.rejects(second.race(Promise.resolve()),/failed to spawn/);
});

test('actual harness rejects each plist mismatch without launching executable or creating data', {skip:process.platform!=='darwin'}, async()=>{
 const {mkdtemp,mkdir,writeFile,chmod,rm,access}=await import('node:fs/promises');
 const {execFileSync,spawnSync}=await import('node:child_process');
 const root=await mkdtemp('/tmp/neura-browser-preflight-');
 try {
  const app=root+'/candidate.app',data=root+'-data',marker=root+'/launched';
  await mkdir(app+'/Contents/MacOS',{recursive:true});
  await writeFile(app+'/Contents/MacOS/NeuraOS',`#!/bin/sh\ntouch '${marker}'\n`);await chmod(app+'/Contents/MacOS/NeuraOS',0o700);
  for(const field of ['CFBundleIdentifier','NeuraDataDirectory','NeuraEndpoint']){
   const config={...good,NeuraDataDirectory:data,[field]:field==='CFBundleIdentifier'?'app.neuraos.native':field==='NeuraDataDirectory'?'/tmp/neura-browser-other':'http://127.0.0.1:44320'};
   await writeFile(app+'/Contents/Info.plist',JSON.stringify(config));execFileSync('/usr/bin/plutil',['-convert','xml1',app+'/Contents/Info.plist']);
   const result=spawnSync(process.execPath,['--import','tsx','scripts/native/chromium/browser-smoke.ts'],{env:{...process.env,NEURA_APP_OUTPUT:app,NEURA_DEV_DATA_DIR:data,NEURA_DEV_PORT:'44319'},encoding:'utf8',timeout:5000});
   assert.equal(result.status,1,result.stderr);assert.match(result.stderr,new RegExp(field));
   await assert.rejects(access(marker));await assert.rejects(access(data));
  }
 }finally{await rm(root,{recursive:true,force:true});}
});
