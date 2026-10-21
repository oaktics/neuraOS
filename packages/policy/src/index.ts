import {ArtifactName} from '../../contracts/src/artifact-name.ts';
import { createHash } from 'node:crypto';
import type { Action, Approval, Run, Task } from '../../contracts/src/index.ts';
export class DomainError extends Error { constructor(public code:string, message=code, public status=409) {super(message);} }
export function ensure(condition:unknown, code:string, message?:string): asserts condition {if(!condition) throw new DomainError(code,message);}
export function canonical(value:unknown):string {
  if(Array.isArray(value)) return `[${value.map(canonical).join(',')}]`;
  if(value !== null && typeof value==='object') return `{${Object.entries(value).sort(([a],[b])=>a.localeCompare(b)).map(([k,v])=>`${JSON.stringify(k)}:${canonical(v)}`).join(',')}}`;
  return JSON.stringify(value);
}
export const hash=(value:unknown)=>createHash('sha256').update(canonical(value)).digest('hex');
export const contentHash=(value:string|Buffer)=>createHash('sha256').update(value).digest('hex');
export function assertLease(task:Task,run:Run,token:number,now:Date) {
  ensure(task.runs.at(-1)?.id===run.id && run.fencingToken===token,'stale_fence');
  ensure(Date.parse(run.leaseUntil)>now.getTime(),'lease_expired');
  ensure(run.planVersion===task.plans.at(-1)?.version,'plan_changed');
  ensure(['running','verifying','waiting_approval','waiting_input'].includes(task.status),'run_not_active');
}
export function assertApproval(action:Action,approval:Approval|undefined,run:Run,now:Date) {
  ensure(approval?.decision==='approved','approval_required');
  ensure(approval.hash===action.hash && approval.planVersion===run.planVersion,'approval_mismatch');
  ensure(Date.parse(approval.expiresAt)>now.getTime(),'approval_expired');
  ensure(action.runId===run.id && action.planVersion===run.planVersion,'action_plan_mismatch');
}
export function assertProvider(task:Task) {
  ensure(task.classification!=='local-only','local_only','外部モデルへ送信できないタスクです。');
  ensure(task.allowedProviders.includes(task.provider),'provider_restricted');
}
export function safeArtifactName(name:string) {ensure(ArtifactName.safeParse(name).success,'invalid_artifact_name');return name;}
