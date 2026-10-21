import {reviewReserve,spentTokens,heldTokens,spentCalls,teamFor,settleUnknown} from './budget.ts';
import {addTask,handleOrganization,refreshTeams} from './organization.ts';
import { randomUUID } from 'node:crypto';
import { CronExpressionParser } from 'cron-parser';
import type { Actor, Command, Envelope, State, Task, Run, Plan, TaskInput, TaskStatus } from '../../contracts/src/index.ts';
import { assertApproval, assertLease, assertProvider, contentHash, ensure, hash, safeArtifactName } from '../../policy/src/index.ts';
import { resolveMemories } from '../../memory/src/index.ts';

export function emptyState(workspaceId:string):State {return {schemaVersion:1,conversations:[],workspaceId,revision:0,tasks:[],projects:[],memories:[],tombstones:[],devices:[],connectors:[],schedules:[],operations:{},audit:[]};}
export function makePlan(input:TaskInput,version:number,requirementsVersion:number,now:string):Plan {
  return {version,requirementsVersion,objective:input.objective,constraints:input.constraints,criteria:structuredClone(input.criteria),createdAt:now,steps:[
    {id:'context',title:'目的と資料を確認',output:'適用範囲を確認した指示・記憶',completion:'権限と機密区分の検査を通過',dependencies:[],retry:'safe'},
    {id:'generate',title:'成果物を作成',output:'名前・形式を持つ成果物',completion:'構造化出力を保存してハッシュを確認',dependencies:['context'],retry:'safe'},
    {id:'verify',title:'完了条件を検証',output:'条件ごとの証拠',completion:'すべての必須条件が合格',dependencies:['generate'],retry:'safe'},
    {id:'deliver',title:'保存して届ける',output:'取得できる成果物と検証結果',completion:input.cloudRequired?'クラウドへ保存後、再取得して一致':'ローカル保存の内容を再取得して一致',dependencies:['verify'],retry:'reconcile'}]};
}
export function currentRun(task:Task):Run {const r=task.runs.at(-1);ensure(r,'run_missing');return r;}
function touch(task:Task,now:string){task.version++;task.updatedAt=now;}
function status(task:Task,value:TaskStatus,reason:string,now:string){task.status=value;task.reason=reason;const r=task.runs.at(-1);if(r){r.status=value;r.reason=reason;if(['succeeded','failed','canceled'].includes(value))r.endedAt=now;}}
const runnerCommands=new Set(['chat.result','team.plan','team.reviewed','run.claim','run.renew','run.release','run.event','run.update','run.reserve','run.settle','artifact.add','artifact.stored','verification.record','run.complete','action.begin','action.result','action.reconcile']);
const unresolved=(task:Task)=>task.actions.some(a=>a.status==='unknown'||a.status==='dispatching');
const active=(task:Task)=>['running','verifying','waiting_approval','waiting_input'].includes(task.status);
export function applyCommand(original:State,envelope:Envelope,actor:Actor,now=new Date()):State {
  const digest=hash(envelope.command),prior=original.operations[envelope.operationId];
  const s=structuredClone(original),c=envelope.command,at=now.toISOString();
  if(runnerCommands.has(c.type)){
    ensure(actor.role==='runner','runner_required');
    ensure(s.devices.some(d=>d.id===actor.deviceId&&d.status==='active'),'device_revoked');
  } else ensure(c.type==='schedule.tick'?actor.role==='scheduler':actor.role==='user','user_required');
  if(prior){ensure(prior.hash===digest,'operation_reused');return original;}
  if(c.type==='schedule.tick'&&!s.tasks.some(t=>t.work?.role==='director'&&t.work.phase==='waiting'&&t.status==='blocked'&&(s.tasks.filter(x=>x.work?.parentId===t.id).every(x=>x.status==='succeeded')||(t.reason!=='team_member_blocked'&&s.tasks.some(x=>x.work?.parentId===t.id&&['failed','blocked','canceled','needs_revision'].includes(x.status)))))&&!s.schedules.some(x=>x.enabled&&Date.parse(x.nextAt)<=now.getTime())&&!s.tasks.some(t=>active(t)&&t.runs.at(-1)&&Date.parse(t.runs.at(-1)!.leaseUntil)<=now.getTime()))return original;
  let t:Task|undefined;
  if('taskId' in c){t=s.tasks.find(x=>x.id===c.taskId);ensure(t,'task_not_found');if('expectedVersion' in c)ensure(t.version===c.expectedVersion,'version_conflict');}
  let run:Run|undefined;
  if('runId' in c){ensure(t,'task_not_found');run=t.runs.find(r=>r.id===c.runId);ensure(run,'run_not_found');ensure(run.runnerId===actor.deviceId,'wrong_runner');if(c.type==='run.release')ensure(run.fencingToken===c.fencingToken,'stale_fence');else if(c.type!=='run.event')assertLease(t,run,c.fencingToken,now);}
  handleOrganization(s,c,actor,at,t);
  switch(c.type){
    case 'task.create': {
      ensure(!s.tasks.some(t=>t.id===c.id),'task_exists');
      validateTask(s,c.input);
      const input=c.input.projectId?{...c.input,provider:s.projects.find(p=>p.id===c.input.projectId)?.provider??c.input.provider}:c.input;addTask(s,c.id,input,at);break;
    }
    case 'task.revise': {
      ensure(!t!.work,'team_revision_requires_new_request');validateTask(s,c.input);ensure(!unresolved(t!),'unresolved_action');
      Object.assign(t!,c.input);t!.requirementsVersion++;t!.plans.push(makePlan(c.input,t!.plans.length+1,t!.requirementsVersion,at));
      status(t!,'draft','requirements_changed',at);break;
    }
    case 'task.queue': ensure(!t!.work||t!.status==='draft','team_run_not_repeatable');ensure(!active(t!)&&!unresolved(t!),'task_busy');validateTask(s,t!);assertProvider(t!);status(t!,'queued','',at);break;
    case 'task.control': {
      if(c.action==='resume'&&t!.work?.role==='director'&&t!.work.phase==='waiting'){
        ensure(['paused','blocked'].includes(t!.status),'invalid_transition');ensure(!unresolved(t!),'unresolved_action');
        for(const child of s.tasks.filter(x=>x.work?.parentId===t!.id&&x.status==='paused')){ensure(!unresolved(child),'unresolved_action');status(child,'queued','parent_resumed',at);touch(child,at);}status(t!,'blocked','waiting_team',at);break;
      }
      if(c.action==='resume'){ensure(['paused','blocked','failed','needs_revision','waiting_input'].includes(t!.status),'invalid_transition');ensure(!unresolved(t!),'unresolved_action');assertProvider(t!);status(t!,'queued','resume_requested',at);}
      else {for(const child of s.tasks.filter(x=>x.work?.parentId===t!.id&&!['succeeded','canceled'].includes(x.status))){status(child,c.action==='pause'?'paused':'canceled','parent_stopped',at);touch(child,at);}ensure(t!.status!=='succeeded','invalid_transition');status(t!,c.action==='pause'?'paused':'canceled',unresolved(t!)?'external_result_unresolved':'user_requested',at);}
      break;
    }
    case 'run.claim': {
      ensure(c.runnerId===actor.deviceId,'wrong_runner');ensure(t!.status==='queued','not_queued');validateTask(s,t!);assertProvider(t!);
      ensure(!unresolved(t!),'unresolved_action');
      if(t!.work?.parentId){const parent=s.tasks.find(x=>x.id===t!.work!.parentId);ensure(parent?.work?.phase==='waiting'&&parent.status==='blocked','parent_not_waiting');}
      const last=t!.runs.at(-1);ensure(!last||Date.parse(last.leaseUntil)<=now.getTime(),'lease_held');
      const token=(last?.fencingToken??0)+1;
      // A fresh attempt never converts an uncertain side effect into a retry.
      const reusable=last&&last.planVersion===t!.plans.at(-1)!.version&&!last.endedAt&&last.runnerId===c.runnerId;
      if(last)settleUnknown(last);
      if(reusable){last.fencingToken=token;last.leaseUntil=new Date(now.getTime()+30000).toISOString();}
      else t!.runs.push({id:randomUUID(),planVersion:t!.plans.at(-1)!.version,provider:t!.provider,model:t!.model,status:'running',reason:'',runnerId:c.runnerId,fencingToken:token,leaseUntil:new Date(now.getTime()+30000).toISOString(),startedAt:at,endedAt:null,sessionId:null,adapterVersion:'pending',calls:0,tokens:0,costUsd:null,sequence:0,memoryVersions:resolveMemories(s,t!,now).map(m=>({id:m.id,version:m.version,reason:`${m.scope}:${m.kind}`})),attempts:[]});
      status(t!,'running','',at);break;
    }
    case 'run.renew': run!.leaseUntil=new Date(now.getTime()+30000).toISOString();s.devices.find(d=>d.id===actor.deviceId)!.lastSeenAt=at;break;
    case 'run.release': settleUnknown(run!);run!.leaseUntil=at;break;
    case 'run.event': {
      const existing=t!.events.find(e=>e.runId===c.runId&&e.sequence===c.sequence);
      if(existing){ensure(existing.id===c.eventId&&existing.kind===c.kind&&existing.message===c.message,'event_conflict');break;}
      ensure(c.sequence===run!.sequence+1,'event_gap');
      const historical=run!.fencingToken!==c.fencingToken||Date.parse(run!.leaseUntil)<=now.getTime()||t!.runs.at(-1)?.id!==run!.id;
      t!.events.push({id:c.eventId,runId:c.runId,sequence:c.sequence,kind:c.kind,message:c.message,createdAt:at,historical});run!.sequence=c.sequence;break;
    }
    case 'run.update': {
      if(c.status){ensure(['running','verifying','waiting_approval','waiting_input','blocked','failed','paused'].includes(c.status),'invalid_transition');status(t!,c.status,c.reason??'',at);}
      if(c.sessionId)run!.sessionId=c.sessionId;if(c.model)run!.model=c.model;if(c.adapterVersion)run!.adapterVersion=c.adapterVersion;
      if(c.calls!==undefined)run!.calls=Math.max(run!.calls,c.calls);if(c.tokens!==undefined)run!.tokens=Math.max(run!.tokens,c.tokens);if(c.costUsd!==undefined)run!.costUsd=c.costUsd;break;
    }
    case 'run.reserve': {
      const tokens=c.tokens??1,calls=c.calls??1,team=teamFor(s,t!);
      ensure(spentCalls(t!)+calls<=t!.budget.maxCalls,'call_budget');ensure(spentTokens(t!)+heldTokens(t!)+tokens<=t!.budget.maxTokens,'token_budget');
      ensure(!run!.reservedTokens,'reservation_pending');
      if(team){const reserve=t!.work?.role==='employee'?reviewReserve(team.root):0;
        ensure(team.tasks.reduce((n,x)=>n+spentCalls(x),0)+calls+(reserve?2:0)<=team.root.budget.maxCalls,'team_call_budget');
        ensure(team.tasks.reduce((n,x)=>n+spentTokens(x)+heldTokens(x),0)+tokens+reserve<=team.root.budget.maxTokens,'team_token_budget');
      }
      ensure(now.getTime()-Date.parse(run!.startedAt)<t!.budget.maxSeconds*1000,'time_budget');
      // Codex does not expose a hard dollar cap; never claim a monetary guarantee.
      ensure(t!.budget.maxUsd===null||t!.provider==='claude','cost_cap_unsupported');
      ensure(t!.budget.maxUsd===null||(run!.costUsd??0)<t!.budget.maxUsd,'cost_budget');run!.calls++;run!.reservedTokens=tokens;run!.reservedCalls=calls-1;break;
    }
    case 'run.settle': {
      ensure(run!.reservedTokens,'reservation_missing');run!.tokens+=c.tokens;run!.calls+=c.calls-1;
      run!.costUsd=c.costUsd===null?null:(run!.costUsd??0)+c.costUsd;run!.reservedTokens=0;run!.reservedCalls=0;break;
    }
    case 'artifact.add': {
      ensure(!t!.artifacts.some(a=>a.id===c.id),'artifact_exists');safeArtifactName(c.name);
      t!.artifacts.push({id:c.id,name:c.name,content:c.content,mediaType:c.mediaType,hash:contentHash(c.content),size:Buffer.byteLength(c.content),runId:c.runId,createdAt:at,cloudKey:null,cloudVerifiedAt:null});break;
    }
    case 'artifact.stored': {const a=t!.artifacts.find(a=>a.id===c.artifactId&&a.runId===c.runId);ensure(a&&a.hash===c.hash,'artifact_hash_mismatch');a.cloudKey=c.key;a.cloudVerifiedAt=at;break;}
    case 'verification.record': {
      const criterion=t!.criteria.find(x=>x.id===c.criterionId);ensure(criterion&&criterion.kind!=='human','human_acceptance_required');
      t!.verifications.push({id:randomUUID(),criterionId:c.criterionId,runId:c.runId,passed:c.passed,evidence:c.evidence,environment:c.environment,verifier:actor.id,createdAt:at});break;
    }
    case 'verification.accept': {
      if(t!.work?.role==='director')ensure(t!.work.phase==='finished'&&t!.status==='waiting_input','team_not_ready_for_acceptance');
      ensure(t!.criteria.some(x=>x.id===c.criterionId&&x.kind==='human'),'not_human_criterion');
      const r=currentRun(t!);ensure(t!.artifacts.some(a=>a.runId===r.id),'artifact_missing');
      t!.verifications.push({id:randomUUID(),criterionId:c.criterionId,runId:r.id,passed:c.passed,evidence:c.evidence,environment:'user',verifier:actor.id,createdAt:at});break;
    }
    case 'run.complete': {
      if(t!.work?.role==='director')ensure(t!.work.phase==='finished'&&s.tasks.filter(x=>x.work?.parentId===t!.id).every(x=>x.status==='succeeded'),'team_incomplete');
      ensure(!t!.actions.some(a=>['proposed','dispatching','unknown'].includes(a.status)),'unresolved_action');
      const artifacts=t!.artifacts.filter(a=>a.runId===run!.id);ensure(artifacts.length>0&&artifacts.every(a=>a.hash===contentHash(a.content)),'artifact_missing');
      ensure(!t!.cloudRequired||artifacts.every(a=>a.cloudVerifiedAt&&a.cloudKey),'cloud_save_required');
      const failed=t!.criteria.filter(c=>c.required).filter(c=>!t!.verifications.filter(v=>v.runId===run!.id&&v.criterionId===c.id).at(-1)?.passed);
      if(failed.length){status(t!,failed.some(c=>c.kind==='human')?'waiting_input':'needs_revision','criteria_unmet',at);}
      else status(t!,'succeeded','verified',at);break;
    }
    case 'action.propose': {
      const r=currentRun(t!);ensure(['running','verifying','waiting_input','waiting_approval'].includes(t!.status),'invalid_transition');
      ensure(t!.classification==='standard','external_write_classification');
      const connector=s.connectors.find(x=>x.id===c.connectorId&&x.enabled);ensure(connector&&connector.resource===c.target,'connector_scope');
      ensure(!s.tasks.some(x=>x.actions.some(a=>a.idempotencyKey===c.idempotencyKey)),'action_key_reused');
      const a={id:randomUUID(),runId:r.id,planVersion:r.planVersion,kind:'github.issue.create' as const,connectorId:c.connectorId,target:c.target,payload:{title:c.title,body:c.body},idempotencyKey:c.idempotencyKey,status:'proposed' as const,externalId:null,resultUrl:null,createdAt:at};
      const digest=hash({kind:a.kind,target:a.target,payload:a.payload,planVersion:a.planVersion,connectorId:a.connectorId});
      t!.actions.push({...a,hash:digest});t!.approvals.push({id:randomUUID(),actionId:a.id,hash:digest,planVersion:r.planVersion,expiresAt:new Date(now.getTime()+3600000).toISOString(),decision:'pending',actor:null,decidedAt:null});status(t!,'waiting_approval','external_write',at);break;
    }
    case 'approval.decide': {
      const a=t!.approvals.find(a=>a.id===c.approvalId);ensure(a?.decision==='pending','approval_not_pending');
      ensure(a.hash===c.hash&&a.planVersion===t!.plans.at(-1)!.version,'approval_mismatch');ensure(Date.parse(a.expiresAt)>now.getTime(),'approval_expired');
      a.decision=c.decision;a.actor=actor.id;a.decidedAt=at;if(c.decision==='denied')t!.actions.find(x=>x.id===a.actionId)!.status='denied';break;
    }
    case 'action.begin': {
      const a=t!.actions.find(a=>a.id===c.actionId);ensure(a&&a.status==='proposed','action_not_dispatchable');
      const connector=s.connectors.find(x=>x.id===a.connectorId);ensure(connector?.enabled&&connector.resource===a.target,'connector_scope');
      assertApproval(a,t!.approvals.find(x=>x.actionId===a.id),run!,now);a.status='dispatching';break;
    }
    case 'action.result': {const a=t!.actions.find(x=>x.id===c.actionId);ensure(a&&a.status==='dispatching','action_not_dispatched');a.status=c.outcome;a.externalId=c.externalId;a.resultUrl=c.resultUrl;break;}
    case 'action.reconcile': {const a=t!.actions.find(x=>x.id===c.actionId);ensure(a&&['unknown','dispatching'].includes(a.status),'action_not_uncertain');ensure(c.resultUrl===`https://github.com/${a.target}/issues/${c.externalId}`,'external_url_mismatch');a.status='succeeded';a.externalId=c.externalId;a.resultUrl=c.resultUrl;break;}
    case 'project.save': {const p=s.projects.find(p=>p.id===c.id);const value={id:c.id,name:c.name,description:c.description,instructions:c.instructions,classification:c.classification,provider:c.provider??p?.provider??'codex',maxWorkers:c.maxWorkers??p?.maxWorkers??3,createdAt:p?.createdAt??at};if(p)Object.assign(p,value);else s.projects.push(value);break;}
    case 'memory.save': {
      ensure(!s.tombstones.some(t=>t.id===c.id),'memory_deleted');const m=s.memories.find(m=>m.id===c.id);ensure((m?.version??0)===c.expectedVersion,'version_conflict');
      ensure(!/\b(sk-[A-Za-z0-9_-]{16,}|gh[pousr]_[A-Za-z0-9]{20,}|-----BEGIN .*PRIVATE KEY-----)/.test(c.input.content),'secret_in_memory');
      if(c.input.scope==='project')ensure(s.projects.some(p=>p.id===c.input.scopeId),'project_not_found');
      if(c.input.scope==='task')ensure(s.tasks.some(t=>t.id===c.input.scopeId),'task_not_found');
      if(['workspace','user-global'].includes(c.input.scope))ensure(c.input.scopeId===null,'invalid_scope');
      const value={...c.input,id:c.id,version:(m?.version??0)+1,state:c.input.explicit?'active' as const:'proposed' as const,createdAt:m?.createdAt??at,updatedAt:at};
      if(m)Object.assign(m,value);else s.memories.push(value);break;
    }
    case 'memory.state': {const m=s.memories.find(x=>x.id===c.id);ensure(m&&m.version===c.expectedVersion,'version_conflict');ensure(!m.expiresAt||Date.parse(m.expiresAt)>now.getTime(),'memory_expired');m.state=c.state;m.version++;m.updatedAt=at;break;}
    case 'memory.delete': {
      const m=s.memories.find(x=>x.id===c.id);ensure(m&&m.version===c.expectedVersion,'version_conflict');s.tombstones.push({id:c.id,deletedAt:at});s.memories=s.memories.filter(x=>x.id!==c.id);
      for(const task of s.tasks)for(const r of task.runs)r.memoryVersions=r.memoryVersions.filter(m=>m.id!==c.id);break;
    }
    case 'connector.save': {const value={id:c.id,kind:'github' as const,name:c.name,account:c.account,resource:c.resource,enabled:c.enabled};const found=s.connectors.find(x=>x.id===c.id);if(found)Object.assign(found,value);else s.connectors.push(value);break;}
    case 'device.register': {ensure(!s.devices.some(d=>d.id===c.id),'device_exists');s.devices.push({id:c.id,name:c.name,publicKey:c.publicKey,status:'active',lastSeenAt:at,createdAt:at});break;}
    case 'device.revoke': {const d=s.devices.find(d=>d.id===c.id);ensure(d,'device_missing');d.status='revoked';for(const task of s.tasks){const r=task.runs.at(-1);if(r?.runnerId===d.id&&active(task)){status(task,'blocked','device_revoked',at);touch(task,at);}}break;}
    case 'schedule.save': {ensure(s.tasks.some(t=>t.id===c.input.taskId),'task_not_found');ensure(!s.tasks.find(t=>t.id===c.input.taskId)!.work,'team_schedule_requires_new_request');const next=CronExpressionParser.parse(c.input.cron,{tz:c.input.timezone,currentDate:now}).next().toISOString()!;const found=s.schedules.find(x=>x.id===c.id);const value={...c.input,id:c.id,nextAt:next,lastAt:found?.lastAt??null};if(found)Object.assign(found,value);else s.schedules.push(value);break;}
    case 'schedule.tick': {
      refreshTeams(s,at);
      for(const sch of s.schedules.filter(x=>x.enabled&&Date.parse(x.nextAt)<=now.getTime())){
        const task=s.tasks.find(t=>t.id===sch.taskId)!;const busy=active(task)||task.status==='queued'||unresolved(task);
        if(busy&&sch.overlap==='wait')continue;
        const late=now.getTime()-Date.parse(sch.nextAt)>60000;
        if(!busy&&(!late||sch.misfire==='once')){assertProvider(task);status(task,'queued','scheduled',at);touch(task,at);}
        sch.lastAt=sch.nextAt;sch.nextAt=CronExpressionParser.parse(sch.cron,{tz:sch.timezone,currentDate:now}).next().toISOString()!;
      }
      for(const task of s.tasks){const r=task.runs.at(-1);if(r&&active(task)&&Date.parse(r.leaseUntil)<=now.getTime()){
        settleUnknown(task.runs.at(-1)!);for(const a of task.actions)if(a.status==='dispatching')a.status='unknown';status(task,'blocked',unresolved(task)?'external_result_unresolved':'runner_disconnected',at);touch(task,at);
      }}break;
    }
  }
  if(t&&c.type!=='run.renew'&&c.type!=='run.event')touch(t,at);
  s.revision++;s.operations[envelope.operationId]={hash:digest,at};
  s.audit.push({id:randomUUID(),actor:actor.id,operation:c.type,target:'taskId' in c?c.taskId:'id' in c?c.id:s.workspaceId,traceId:envelope.operationId,at});
  return s;
}
function validateTask(s:State,input:TaskInput){
  for(const source of input.sources){ensure(source.classification!=='local-only'||input.classification==='local-only','classification_downgrade');ensure(source.classification!=='restricted'||input.classification!=='standard','classification_downgrade');}
  ensure(input.criteria.some(c=>c.required),'required_criterion_missing');ensure(new Set(input.criteria.map(c=>c.id)).size===input.criteria.length,'duplicate_criterion');
  if(input.projectId){const p=s.projects.find(p=>p.id===input.projectId);ensure(p,'project_not_found');ensure(p.classification!=='local-only'||input.classification==='local-only','classification_downgrade');ensure(p.classification!=='restricted'||input.classification!=='standard','classification_downgrade');}
  ensure(!input.cloudRequired||input.classification!=='local-only','classification_conflict');
}
