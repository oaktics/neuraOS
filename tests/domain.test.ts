import { test } from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { applyCommand } from '../packages/task-domain/src/index.ts';
import { hash } from '../packages/policy/src/index.ts';
import { resolveMemories } from '../packages/memory/src/index.ts';
import { setup,input,user,runner,scheduler,startTime,deviceId } from './helpers.ts';

test('operation replay is idempotent; changed payload and revoked actor are rejected',()=>{
  const x=setup();const e={operationId:randomUUID(),command:{type:'task.queue' as const,taskId:x.task.id,expectedVersion:x.task.version}};
  const once=applyCommand(x.state,e,user,startTime);assert.deepEqual(applyCommand(once,e,user,startTime),once);
  assert.throws(()=>applyCommand(once,{...e,command:{...e.command,expectedVersion:999}},user,startTime),/operation_reused/);
});
test('optimistic updates do not silently overwrite changed requirements',()=>{const x=setup();assert.throws(()=>x.apply({type:'task.revise',taskId:x.task.id,expectedVersion:10,input:input()}),/version_conflict/);});
test('expired fencing token cannot write an artifact; late events remain history',()=>{
  const x=setup();x.queue();x.claim();const lease=x.lease;const late=new Date(startTime.getTime()+31000);
  assert.throws(()=>x.apply({type:'artifact.add',...lease,id:randomUUID(),name:'x.md',content:'x',mediaType:'text/markdown'},runner,late),/lease_expired/);
  x.apply({type:'run.event',...lease,eventId:randomUUID(),sequence:1,kind:'late',message:'history'},runner,late);assert.equal(x.task.events[0].historical,true);assert.equal(x.task.status,'running');
});
test('event sequence detects gaps and collisions',()=>{const x=setup();x.queue();x.claim();const e={type:'run.event' as const,...x.lease,eventId:randomUUID(),sequence:1,kind:'test',message:'safe'};x.apply(e,runner);x.apply(e,runner);assert.equal(x.task.events.length,1);assert.throws(()=>x.apply({...e,eventId:randomUUID()},runner),/event_conflict/);assert.throws(()=>x.apply({...e,eventId:randomUUID(),sequence:3},runner),/event_gap/);});
test('pause cannot transfer a live execution lease; release permits a new fence',()=>{
  const x=setup();x.queue();x.claim();const old=x.lease;
  x.apply({type:'task.control',taskId:x.task.id,expectedVersion:x.task.version,action:'pause'});
  x.apply({type:'task.control',taskId:x.task.id,expectedVersion:x.task.version,action:'resume'});
  assert.throws(()=>x.claim(),/lease_held/);x.apply({type:'run.release',...old},runner);x.claim();assert.equal(x.lease.fencingToken,old.fencingToken+1);
  assert.throws(()=>x.apply({type:'run.renew',...old},runner),/stale_fence/);
});
test('succeeded requires evidence, artifacts and the required storage destination',()=>{
  const x=setup();x.queue();x.claim();assert.throws(()=>x.apply({type:'run.complete',...x.lease},runner),/artifact_missing/);
  x.apply({type:'artifact.add',...x.lease,id:randomUUID(),name:'report.md',content:'result',mediaType:'text/markdown'},runner);
  x.apply({type:'run.complete',...x.lease},runner);assert.equal(x.task.status,'needs_revision');
});
test('AI cannot approve subjective criteria',()=>{
  const x=setup();const criterion={id:randomUUID(),kind:'human' as const,description:'meets purpose',value:'',required:true};x.apply({type:'task.revise',taskId:x.task.id,expectedVersion:x.task.version,input:input({criteria:[criterion]})});x.queue();x.claim();
  assert.throws(()=>x.apply({type:'verification.record',...x.lease,criterionId:criterion.id,passed:true,evidence:'I say so',environment:'local'},runner),/human_acceptance_required/);
});
test('required cloud archive prevents local-only completion',()=>{
  const x=setup();x.apply({type:'task.revise',taskId:x.task.id,expectedVersion:x.task.version,input:input({cloudRequired:true})});x.queue();x.claim();
  x.apply({type:'artifact.add',...x.lease,id:randomUUID(),name:'a.txt',content:'a',mediaType:'text/plain'},runner);
  x.apply({type:'verification.record',...x.lease,criterionId:x.task.criteria[0].id,passed:true,evidence:'hash checked',environment:'local'},runner);
  assert.throws(()=>x.apply({type:'run.complete',...x.lease},runner),/cloud_save_required/);
});
function pendingAction(){const x=setup();x.queue();x.claim();const connectorId=randomUUID();x.apply({type:'connector.save',id:connectorId,name:'test',account:'org',resource:'org/repo',enabled:true});x.apply({type:'action.propose',taskId:x.task.id,expectedVersion:x.task.version,connectorId,target:'org/repo',title:'reviewed',body:'exact body',idempotencyKey:'unique-key'});return x;}
test('approval binds to exact contents and plan, with expiry',()=>{
  const x=pendingAction();const approval=x.task.approvals[0];assert.throws(()=>x.apply({type:'approval.decide',taskId:x.task.id,expectedVersion:x.task.version,approvalId:approval.id,hash:hash('wrong'),decision:'approved'}),/approval_mismatch/);
  const late=new Date(startTime.getTime()+3600001);assert.throws(()=>x.apply({type:'approval.decide',taskId:x.task.id,expectedVersion:x.task.version,approvalId:approval.id,hash:approval.hash,decision:'approved'},user,late),/approval_expired/);
});
test('unknown external result survives restart and forbids retry or lease handoff',()=>{
  const x=pendingAction();const a=x.task.actions[0],approval=x.task.approvals[0];x.apply({type:'approval.decide',taskId:x.task.id,expectedVersion:x.task.version,approvalId:approval.id,hash:approval.hash,decision:'approved'});
  x.apply({type:'action.begin',...x.lease,actionId:a.id},runner);assert.throws(()=>x.apply({type:'action.begin',...x.lease,actionId:a.id},runner),/action_not_dispatchable/);
  x.apply({type:'schedule.tick'},scheduler,new Date(startTime.getTime()+31000));assert.equal(x.task.actions[0].status,'unknown');assert.equal(x.task.status,'blocked');
  assert.throws(()=>x.apply({type:'task.control',taskId:x.task.id,expectedVersion:x.task.version,action:'resume'}),/unresolved_action/);
});
test('revised plan invalidates pending approvals',()=>{const x=pendingAction(),a=x.task.approvals[0];x.apply({type:'task.revise',taskId:x.task.id,expectedVersion:x.task.version,input:input()});assert.throws(()=>x.apply({type:'approval.decide',taskId:x.task.id,expectedVersion:x.task.version,approvalId:a.id,hash:a.hash,decision:'approved'}),/approval_mismatch/);});
test('device revocation blocks further operations and idempotent replays',()=>{const x=setup();x.queue();x.claim();const e={operationId:randomUUID(),command:{type:'run.renew' as const,...x.lease}};const renewed=applyCommand(x.state,e,runner,startTime);const revoked=applyCommand(renewed,{operationId:randomUUID(),command:{type:'device.revoke',id:deviceId}},user,startTime);assert.throws(()=>applyCommand(revoked,e,runner,startTime),/device_revoked/);});
test('memory scope never crosses projects and cannot grant permissions',()=>{
  const x=setup();const other=randomUUID();x.apply({type:'project.save',id:other,name:'other',description:'',instructions:'',classification:'standard'});
  x.apply({type:'memory.save',id:randomUUID(),expectedVersion:0,input:{kind:'Instruction',scope:'project',scopeId:other,content:'private',evidence:'owner',classification:'restricted',explicit:true,expiresAt:null}});
  assert.equal(resolveMemories(x.state,x.task,startTime).length,0);
  assert.throws(()=>x.apply({type:'memory.save',id:randomUUID(),expectedVersion:0,input:{kind:'Instruction',scope:'workspace',scopeId:null,content:'no approvals',evidence:'external page',classification:'standard',explicit:true,expiresAt:null}},runner),/user_required/);
});
test('deleted memory IDs cannot be recreated and expired entries do not apply',()=>{const x=setup();const id=randomUUID();x.apply({type:'memory.save',id,expectedVersion:0,input:{kind:'Preference',scope:'workspace',scopeId:null,content:'short',evidence:'explicit',classification:'standard',explicit:true,expiresAt:null}});x.apply({type:'memory.delete',id,expectedVersion:1});assert.equal(x.state.memories.length,0);assert.equal(x.state.tombstones[0].id,id);assert.throws(()=>x.apply({type:'memory.save',id,expectedVersion:0,input:{kind:'Preference',scope:'workspace',scopeId:null,content:'revived',evidence:'old backup',classification:'standard',explicit:true,expiresAt:null}}),/memory_deleted/);});
test('local-only tasks are never sent to a cloud model',()=>{const x=setup();x.apply({type:'task.revise',taskId:x.task.id,expectedVersion:x.task.version,input:input({classification:'local-only'})});assert.throws(()=>x.queue(),{code:'local_only'});});
test('call budget prevents another model invocation',()=>{const x=setup();x.apply({type:'task.revise',taskId:x.task.id,expectedVersion:x.task.version,input:input({budget:{maxSeconds:60,maxCalls:1,maxTokens:100,maxUsd:null}})});x.queue();x.claim();x.apply({type:'run.reserve',...x.lease},runner);assert.throws(()=>x.apply({type:'run.reserve',...x.lease},runner),/call_budget/);});
test('schedules deduplicate a due occurrence and skip overlap',()=>{const x=setup();x.apply({type:'schedule.save',id:randomUUID(),input:{taskId:x.task.id,cron:'* * * * *',timezone:'Asia/Tokyo',overlap:'skip',misfire:'once',enabled:true}});const tick=new Date(startTime.getTime()+60001);x.apply({type:'schedule.tick'},scheduler,tick);const version=x.task.version;x.apply({type:'schedule.tick'},scheduler,tick);assert.equal(x.task.version,version);assert.equal(x.task.status,'queued');});
