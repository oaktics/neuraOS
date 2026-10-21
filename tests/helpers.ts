import { randomUUID } from 'node:crypto';
import type { Actor, Command, State, TaskInput } from '../packages/contracts/src/index.ts';
import { applyCommand, emptyState } from '../packages/task-domain/src/index.ts';
export const user:Actor={id:'owner',role:'user'};
export const deviceId=randomUUID();
export const runner:Actor={id:deviceId,role:'runner',deviceId};
export const scheduler:Actor={id:'scheduler',role:'scheduler'};
export const startTime=new Date('2026-10-21T00:00:00.000Z');
export function input(changes:Partial<TaskInput>={}):TaskInput{return {title:'調査メモ',objective:'提供した資料から検証可能なメモを作る',constraints:'推測は明示',sources:[],provider:'fixture',model:'',projectId:null,classification:'standard',allowedProviders:['codex','claude','fixture'],criteria:[{id:randomUUID(),kind:'artifact',description:'取得できる成果物',value:'',required:true}],budget:{maxSeconds:600,maxCalls:4,maxTokens:50000,maxUsd:null},cloudRequired:false,dueAt:null,...changes};}
export function setup(){let state=emptyState(randomUUID());const taskId=randomUUID();const apply=(command:Command,actor=user,at=startTime)=>state=applyCommand(state,{operationId:randomUUID(),command},actor,at);
  apply({type:'device.register',id:deviceId,name:'test',publicKey:'test-key'});
  apply({type:'task.create',id:taskId,input:input()});
  return {get state(){return state;},get task(){return state.tasks[0];},get lease(){const run=state.tasks[0].runs.at(-1)!;return {taskId,runId:run.id,fencingToken:run.fencingToken};},apply,queue:()=>apply({type:'task.queue',taskId,expectedVersion:state.tasks[0].version}),claim:()=>apply({type:'run.claim',taskId,runnerId:deviceId},runner)};
}
