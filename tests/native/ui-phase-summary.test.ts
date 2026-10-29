import {test} from 'node:test';
import assert from 'node:assert/strict';
import {uiPhaseIDs,summarizePhases} from '../../scripts/native/release/ui-phase-summary.mjs';
test('every interrupted phase retains last start, completion, index and deadline',()=>{
 const entries=[];
 for(const [index,phase] of uiPhaseIDs.entries()){
  entries.push({phase,state:'start',elapsedMs:index*100,index,deadlineMs:2000});
  const summary=summarizePhases(entries.map(e=>JSON.stringify(e)).join('\n')+'\n{"partial":');
  assert.equal(summary.lastStarted!.phase,phase);
  assert.equal(summary.lastStarted!.index,index);
  assert.equal(summary.lastCompleted?.phase,index?uiPhaseIDs[index-1]:undefined);
  assert.equal(summary.deadlines.at(-1)!.expectedByElapsedMs,index*100+2000);
  entries.push({phase,state:'complete',elapsedMs:index*100+50,index});
 }
 assert.equal(summarizePhases('secret\n{"phase":"password","state":"start","elapsedMs":1}').lastStarted,null);
});
