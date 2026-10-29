import {test} from 'node:test';
import assert from 'node:assert/strict';
import {mkdtemp,writeFile,readFile,rm} from 'node:fs/promises';
import {spawn,execFileSync} from 'node:child_process';
import {uiPhaseIDs,summarizePhases} from '../../scripts/native/release/ui-phase-summary.mjs';

test('actual Swift phase writer flushes every interrupted phase to its isolated file', {skip:process.platform!=='darwin',timeout:60000}, async()=>{
 const directory=await mkdtemp('/tmp/neura-ui-phase-writer-');
 try {
  await writeFile(directory+'/Runner.swift',`import Foundation
@main struct Runner {
 @MainActor static func main() throws {
  try SmokePhase.configure(directory: URL(fileURLWithPath: CommandLine.arguments[1]))
  for (index, phase) in SmokePhase.ids.enumerated() {
   SmokePhase.record(phase, "start", index: index, deadlineMs: 100)
   SmokePhase.record(phase, "complete", index: index)
  }
 }
}`);
  execFileSync('swiftc',['-j','2','apps/macos/Sources/NeuraOS/SmokePhase.swift',directory+'/Runner.swift','-o',directory+'/writer'],{timeout:30000,stdio:'pipe'});
  for(const [index,phase] of uiPhaseIDs.entries()){
   const child=spawn(directory+'/writer',[directory],{env:{...process.env,NEURA_UI_SMOKE_STALL_PHASE:phase},stdio:'ignore'});
   const exited=new Promise(resolve=>child.once('exit',resolve));
   try {
    let reached=false;
    for(let i=0;i<100;i++){
     try {const text=await readFile(directory+'/ui-phases.jsonl','utf8');if(summarizePhases(text).lastStarted?.phase===phase){reached=true;break;}} catch {}
     await new Promise(r=>setTimeout(r,20));
    }
    assert.ok(reached,phase);
    await new Promise(r=>setTimeout(r,120)); // beyond the phase's test deadline
   }finally{child.kill('SIGKILL');await exited;}
   const summary=summarizePhases(await readFile(directory+'/ui-phases.jsonl','utf8'));
   assert.equal(summary.lastStarted?.phase,phase);
   assert.equal(summary.lastStarted?.index,index);
   assert.equal(summary.lastCompleted?.phase,index?uiPhaseIDs[index-1]:undefined);
  }
 }finally{await rm(directory,{recursive:true,force:true});}
});
