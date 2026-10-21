import type {State,Task,Run} from '../../contracts/src/index.ts';
export const reviewReserve=(task:Task)=>Math.min(40000,Math.max(100,Math.floor(task.budget.maxTokens*.25)));
export const spentTokens=(task:Task)=>task.runs.reduce((n,r)=>n+r.tokens,0);
export const heldTokens=(task:Task)=>task.runs.reduce((n,r)=>n+(r.reservedTokens??0),0);
export const spentCalls=(task:Task)=>task.runs.reduce((n,r)=>n+r.calls+(r.reservedCalls??0),0);
export function teamFor(state:State,task:Task){const root=task.work?.parentId?state.tasks.find(t=>t.id===task.work!.parentId):task;return root?.work?.role==='director'?{root,tasks:state.tasks.filter(t=>t.id===root.id||t.work?.parentId===root.id)}:undefined;}
/** An interrupted request may have reached the provider. Keep a conservative estimate. */
export function settleUnknown(run:Run){if(run.reservedTokens){run.tokens+=run.reservedTokens;run.calls+=run.reservedCalls??0;run.usageEstimated=true;}run.reservedTokens=0;run.reservedCalls=0;}
export function turnAllowance(state:State,task:Task){
 const team=teamFor(state,task);let tokens=task.budget.maxTokens-spentTokens(task),calls=task.budget.maxCalls-spentCalls(task);
 if(team){const review=reviewReserve(team.root),remaining=team.root.budget.maxTokens-team.tasks.reduce((n,t)=>n+spentTokens(t)+heldTokens(t),0),remainingCalls=team.root.budget.maxCalls-team.tasks.reduce((n,t)=>n+spentCalls(t),0);
  if(task.work?.phase==='planning'){tokens=Math.min(tokens,Math.floor(task.budget.maxTokens*.2));calls=Math.min(calls,3);}
  else if(task.work?.role==='employee'){tokens=Math.min(tokens,remaining-review);calls=Math.min(calls,remainingCalls-2);}
  else {tokens=Math.min(tokens,remaining,40000);calls=Math.min(calls,remainingCalls,3);}
 }
 return {tokens:Math.max(0,tokens),calls:Math.max(0,calls)};
}
