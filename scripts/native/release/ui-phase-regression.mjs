// Run only against a disposable candidate built from the current sources.
// Each case really stops the Swift fixture at the named phase and kills only its process group.
import {spawn,execFileSync} from 'node:child_process';
import {readFile,mkdir,writeFile} from 'node:fs/promises';
import {resolve,join} from 'node:path';
import assert from 'node:assert/strict';
import {uiPhaseIDs,uiFailureSummary} from './ui-phase-summary.mjs';
const app=resolve(process.env.NEURA_APP_OUTPUT??'');
const plist=JSON.parse(execFileSync('/usr/bin/plutil',['-convert','json','-o','-',join(app,'Contents/Info.plist')],{encoding:'utf8'}));
assert.ok(plist.CFBundleIdentifier?.startsWith('com.neuraos.reliability-smoke.'));
const data=plist.NeuraDataDirectory;
assert.match(data,/^\/(?:private\/)?tmp\/neura-ui-phase-[\w.-]+$/);
assert.equal(plist.NeuraEndpoint,'http://127.0.0.1:1');
await mkdir(data,{recursive:true});
const requested=process.argv.slice(2);
assert.ok(requested.every(p=>[...uiPhaseIDs,'success'].includes(p)), 'Unknown phase');
const results=[];
for(const phase of requested.length?requested:[...uiPhaseIDs,'success']){
 const child=spawn(join(app,'Contents/MacOS/NeuraOS'),['--reliability-smoke',join(data,'diagnostic-report.json'),'--with-chromium'],{env:{...process.env,NEURA_UI_SMOKE_STALL_PHASE:phase==='success'?'':phase},stdio:['ignore','pipe','pipe'],detached:true});
 let output='';child.stdout.on('data',b=>output+=b);child.stderr.on('data',b=>output+=b);
 let code,signal,done=false,spawnError;
 child.on('error',e=>{spawnError=e;done=true});child.on('exit',(c,s)=>{code=c;signal=s;done=true});
 const started=Date.now();let reached=false;
 try{
  while(!done && Date.now()-started<30000){
   const summary=await uiFailureSummary(data);
   if(phase!=='success'&&summary.lastStarted?.phase===phase){
    // Wait beyond a short fixture deadline to verify flushed evidence survives termination.
    await new Promise(r=>setTimeout(r,250));reached=true;break;
   }
   await new Promise(r=>setTimeout(r,50));
  }
 }finally{
  if(child.pid){try{process.kill(-child.pid,'SIGKILL')}catch{if(!done)child.kill('SIGKILL')}}
  while(!done)await new Promise(r=>setTimeout(r,20));
 }
 const summary=await uiFailureSummary(data);
 await writeFile(join(data,phase+'.phases.jsonl'),await readFile(join(data,'ui-phases.jsonl')));
 await writeFile(join(data,phase+'.log'),output);
 results.push({phase,code,signal,reached,summary});
 await writeFile(join(data,'phase-regression.json'),JSON.stringify(results,null,2));
 if(spawnError)throw spawnError;
 if(phase==='success'){assert.equal(code,0,output);assert.equal(summary.lastCompleted?.phase,'exit');}
 else {assert.ok(reached,`${phase} not reached: ${JSON.stringify(summary)} ${output}`);assert.equal(summary.lastStarted?.phase,phase);assert.equal(signal,'SIGKILL');}
 console.log(`UI phase fixture ${phase}: passed`);
}
console.log(`UI phase evidence: ${data}`);
