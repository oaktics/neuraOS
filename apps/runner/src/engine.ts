import {readGeneration,saveGeneration,persistGeneration} from './generation.ts';
import {turnAllowance} from '../../../packages/task-domain/src/budget.ts';
import {contextOptions,boundedText,reviewContext} from '../../../packages/workspace/src/context.ts';
import {WorkspaceManager} from '../../../packages/workspace/src/manager.ts';
import { randomUUID } from 'node:crypto';
import { join } from 'node:path';
import { mkdir } from 'node:fs/promises';
import { ChatReply, TeamPlan, type Command, type Task, type Run } from '../../../packages/contracts/src/index.ts';
import type { AgentAdapter } from '../../../packages/adapters/index.ts';
import { CodexAdapter } from '../../../packages/adapters/codex/index.ts';
import { ClaudeAdapter } from '../../../packages/adapters/claude/index.ts';
import { FixtureAdapter } from '../../../packages/adapters/fixture.ts';
import { resolveMemories } from '../../../packages/memory/src/index.ts';
import { DomainError, ensure } from '../../../packages/policy/src/index.ts';
import { verifyCriterion } from '../../../packages/execution/src/verify.ts';
import { readSecret } from '../../../packages/connectors/src/secrets.ts';
import { GitHubConnector } from '../../../packages/connectors/src/github.ts';
import { log, traced } from '../../../packages/observability/src/index.ts';
import type { Hub } from './hub.ts';

export class Engine {
  readonly adapters:Record<'codex'|'claude'|'fixture',AgentAdapter>={codex:new CodexAdapter(),claude:new ClaudeAdapter(),fixture:new FixtureAdapter()};
  readonly chatDrafts=new Map<string,string>();
  private active=new Map<string,{controller:AbortController;promise:Promise<void>}>();private ticking=false;private stopped=false;
  workspaceBusy:((id:string)=>boolean)=()=>false;
  readonly workspace:WorkspaceManager;
  constructor(readonly hub:Hub){this.workspace=new WorkspaceManager(hub.store,hub.config.dataDir);}
  async capabilities(){return Promise.all(Object.values(this.adapters).map(a=>a.probeCapabilities()));}
  async tick(){
    if(this.ticking||this.stopped)return;this.ticking=true;
    try{
      await this.hub.refresh();if(!this.hub.config.cloudUrl)await this.hub.execute({type:'schedule.tick'},'scheduler');
      for(const [id,job] of this.active){const task=this.hub.read().tasks.find(t=>t.id===id);if(!task||!['running','verifying','waiting_approval','waiting_input'].includes(task.status)||task.runs.at(-1)?.runnerId!==this.hub.config.deviceId)job.controller.abort();}
      // Three work slots plus one reserved slot for the president's conversation.
      if(!this.hub.config.cloudUrl||this.hub.online){
        const chat=(t:Task)=>['vice_president','director_chat'].includes(t.work?.role??'');
        const queued=this.hub.read().tasks.filter(t=>t.status==='queued'&&!this.active.has(t.id)).sort((a,b)=>Number(chat(b))-Number(chat(a)));
        for(const task of queued){const running=this.hub.read().tasks.filter(t=>this.active.has(t.id));if(chat(task)?running.some(chat):running.filter(t=>!chat(t)).length>=3)continue;
          const project=this.hub.read().projects.find(p=>p.id===task.projectId);if(!chat(task)&&task.projectId&&running.filter(t=>!chat(t)&&t.projectId===task.projectId).length>=(project?.maxWorkers??3))continue;
          const controller=new AbortController();const promise=this.run(task.id,controller).finally(()=>this.active.delete(task.id));this.active.set(task.id,{controller,promise});
        }
      }
    }finally{this.ticking=false;}
  }
  async stop(taskId:string){const job=this.active.get(taskId);job?.controller.abort();await job?.promise;}
  async shutdown(){this.stopped=true;for(const j of this.active.values())j.controller.abort();await Promise.allSettled([...this.active.values()].map(j=>j.promise));}
  private async run(taskId:string,controller:AbortController){
    let agentStarted=false;let run:Run|undefined;let heartbeat:NodeJS.Timeout|undefined;let timeout:NodeJS.Timeout|undefined;
    const task=()=>this.hub.read().tasks.find(t=>t.id===taskId)!;
    const lease=()=>({taskId,runId:run!.id,fencingToken:run!.fencingToken});
    const execute=(c:Command)=>this.hub.execute(c,'runner');
    const event=async(kind:string,message:string)=>{
      const key=`sequence:${run!.id}`;const n=Math.max(Number(this.hub.store.meta(key)??0),task().runs.find(r=>r.id===run!.id)!.sequence)+1;
      this.hub.store.setMeta(key,String(n));await execute({type:'run.event',...lease(),eventId:randomUUID(),sequence:n,kind,message});
    };
    try{
      await execute({type:'run.claim',taskId,runnerId:this.hub.config.deviceId});run=structuredClone(task().runs.at(-1)!);
      timeout=setTimeout(()=>controller.abort(new Error('time_budget')),Math.max(1,task().budget.maxSeconds*1000-(Date.now()-Date.parse(run.startedAt))));
      let renewing=false;
      heartbeat=setInterval(()=>{if(renewing)return;renewing=true;execute({type:'run.renew',...lease()}).catch(()=>controller.abort(new Error('lease_lost'))).finally(()=>renewing=false);},8000);
      const dir=join(this.hub.config.dataDir,'runs',run.id);await mkdir(dir,{recursive:true,mode:0o700});
      await event('preflight','実行権、機密区分、予算、プロバイダーを検査します。');
      ensure(task().provider!=='fixture'||this.hub.config.allowFixtures,'fixture_disabled');
      const adapter=this.adapters[task().provider];
      let generation=await readGeneration(dir,run,task().work?.phase??'task');
      const binding=this.workspace.bindings().find(b=>b.projectId===task().projectId);
      let artifacts=task().artifacts.filter(a=>a.runId===run!.id);
      if(!generation&&(artifacts.length===0||task().work?.phase==='reviewing')){
        const caps=await adapter.probeCapabilities();ensure(caps.available&&caps.isolation,'provider_unavailable');ensure(!caps.reason||task().provider==='fixture','authentication_required',caps.reason);
        const allowance=turnAllowance(this.hub.read(),task());ensure(allowance.tokens>=1000,'team_token_budget');ensure(allowance.calls>=1,'team_call_budget');
        await execute({type:'run.reserve',...lease(),...allowance});
        const current=task();const state=this.hub.read(),project=state.projects.find(p=>p.id===current.projectId);
        const conversation=state.conversations?.find(c=>c.id===current.work?.conversationId);
        const organization={appCapabilities:{version:'0.1.0',youCan:['相談に回答','既存プロジェクトへの仕事を提案','渡された範囲の進捗を説明'],userUI:['プロジェクト作成','ローカルCodex/Claude Code選択','部長への依頼','worktree分担開発','ファイル編集','ユーザー用ターミナル','内蔵ブラウザとページ資料の取り込み'],limitations:['チャットからのプロジェクト自動作成は未対応','ブラウザの自律操作は未対応','任意のホストシェルをAIは実行できない','クラウド未設定ではローカル保存のみ'],storage:this.hub.config.cloudUrl?'cloud configured':'local only'},maxWorkers:project?.maxWorkers??3,conversation:['vice_president','director_chat'].includes(current.work?.role??'')?conversation?.messages.slice(-10).map(m=>({role:m.role,content:boundedText(m.content,4000)})):undefined,projects:state.projects.filter(p=>current.projectId?p.id===current.projectId:p.classification==='standard').map(p=>({id:p.id,name:p.name,description:p.description,provider:p.provider??'codex'})),companyStatus:current.work?.role==='vice_president'?state.tasks.filter(t=>t.work?.role==='director'&&state.projects.some(p=>p.id===t.projectId&&p.classification==='standard')).slice(0,20).map(t=>({projectId:t.projectId,title:t.title,status:t.status})):[],children:current.work?.phase==='reviewing'?reviewContext(state.tasks.filter(t=>t.work?.parentId===current.id),allowance.tokens):[],projectTasks:current.work?.role==='director_chat'?state.tasks.filter(t=>t.projectId===current.projectId&&!['vice_president','director_chat'].includes(t.work?.role??'')).slice(0,20).map(t=>({title:t.title,status:t.status,reason:t.reason})):[]};
        const adapterTask=structuredClone(current);if(current.work?.role==='director'){const shares=(project?.maxWorkers??3)+2;adapterTask.budget.maxCalls=Math.min(current.budget.maxCalls,adapterTask.runs.at(-1)!.calls-1+Math.max(1,Math.floor(current.budget.maxCalls/shares)));}
        const tree=this.workspace.worktrees().find(w=>w.taskId===taskId&&w.projectId===current.projectId);
        const workspaceContext=binding&&current.work?.phase!=='reviewing'?{...await this.workspace.snapshot(current.projectId!,tree?taskId:undefined,contextOptions(current,allowance.tokens)),access:'read-only' as const}:undefined;
        if(workspaceContext){await event('workspace.context',`${workspaceContext.files.length}ファイルを参照資料として取得しました。${workspaceContext.truncated?'一部のファイルは省略しています。':''}`);}
        const memories=resolveMemories(this.hub.read(),current,new Date());
        await event('budget.reserved',`${allowance.tokens.toLocaleString()}トークン・最大${allowance.calls}呼び出し分を予約しました。`);
        agentStarted=true;const result=await traced('agent.turn',{taskId,runId:run.id,provider:current.provider},()=>adapter.execute({task:adapterTask,organization,workspace:workspaceContext,allowance,freshSession:!!current.work,memories,projectInstructions:this.hub.read().projects.find(p=>p.id===current.projectId)?.instructions??'',runtimeDir:join(dir,'agent'),signal:controller.signal,onText:async text=>{if(!controller.signal.aborted)this.chatDrafts.set(taskId,text);},onEvent:event,onSession:async(sessionId,model,adapterVersion)=>{await execute({type:'run.update',...lease(),sessionId,model,adapterVersion});}}));
        await execute({type:'run.settle',...lease(),tokens:result.tokens,costUsd:result.costUsd,calls:Math.max(1,result.calls)});controller.signal.throwIfAborted();
        generation=await saveGeneration(dir,run,current.work?.phase??'task',result.output);
      }else if(generation)await event('generation.recovered','保存済みの生成結果を再利用します。モデルの再呼び出しは行いません。');
      if(generation){
        await persistGeneration(dir,generation,()=>task().artifacts,async(id,artifact)=>execute({type:'artifact.add',...lease(),id,...artifact}));
        await event('generation.completed',generation.output.summary);
        if(generation.output.memoryCandidates.length)await event('reflection.candidates',`${generation.output.memoryCandidates.length}件の記憶候補があります。自動では有効化しません。`);
      }
      artifacts=task().artifacts.filter(a=>a.runId===run!.id);
      const current=task();
      if(['vice_president','director_chat'].includes(current.work?.role??'')&&!this.hub.read().conversations?.some(c=>c.messages.some(m=>m.taskId===taskId&&m.role==='assistant'))){
        const answer=artifacts.find(a=>a.name==='response.json');ensure(answer,'chat_response_missing');await execute({type:'chat.result',...lease(),reply:ChatReply.parse(JSON.parse(answer.content))});
      }
      if(current.work?.role==='director'&&current.work.phase==='planning'){
        const plan=artifacts.find(a=>a.name==='team-plan.json');ensure(plan,'team_plan_missing');await execute({type:'team.plan',...lease(),plan:TeamPlan.parse(JSON.parse(plan.content))});return;
      }
      if(current.work?.role==='director'&&current.work.phase==='reviewing')await execute({type:'team.reviewed',...lease()});
      await execute({type:'run.update',...lease(),status:'verifying',reason:''});
      for(const criterion of task().criteria){controller.signal.throwIfAborted();const verification=await verifyCriterion(criterion,artifacts,join(dir,'verification',criterion.id),controller.signal);if(verification)await execute({type:'verification.record',...lease(),criterionId:criterion.id,...verification});}
      if(this.hub.config.cloudUrl){for(const a of artifacts)if(!a.cloudVerifiedAt)await this.hub.archive(a.id);}
      else if(task().cloudRequired)throw new DomainError('cloud_configuration_required');
      await this.processActions(task,run,controller.signal);
      if(task().actions.some(a=>a.status==='proposed'))await execute({type:'run.update',...lease(),status:'waiting_approval',reason:'external_write'});
      else await execute({type:'run.complete',...lease()});
      // Human acceptance and approvals are durable. Continue servicing them with a valid lease.
      while(['waiting_input','waiting_approval'].includes(task().status)&&!controller.signal.aborted){
        await new Promise<void>(resolve=>{const finish=()=>{clearTimeout(timer);controller.signal.removeEventListener('abort',finish);resolve();};const timer=setTimeout(finish,1000);controller.signal.addEventListener('abort',finish,{once:true});});
        await this.processActions(task,run,controller.signal);
        if(task().actions.some(a=>['proposed','unknown','dispatching'].includes(a.status)))continue;
        const latest=task();
        if(latest.criteria.filter(c=>c.required).every(c=>latest.verifications.filter(v=>v.runId===run!.id&&v.criterionId===c.id).at(-1)?.passed))await execute({type:'run.complete',...lease()});
      }
    }catch(error){
      const usage=!agentStarted?{tokens:0,calls:0,costUsd:0}:(error as {usage?:{tokens:number;calls:number;costUsd:null}})?.usage;
      if(run&&usage&&task().runs.at(-1)?.reservedTokens)await execute({type:'run.settle',...lease(),...usage}).catch(()=>{});
      const code=controller.signal.aborted?(controller.signal.reason instanceof Error&&controller.signal.reason.message==='time_budget'?'time_budget':'interrupted'):error instanceof DomainError?error.code:'execution_failed';
      log('run.stopped',{taskId,runId:run?.id??'',code});
      if(run&&['running','verifying','waiting_input','waiting_approval'].includes(task().status)){
        try{await event('run.stopped',error instanceof DomainError?error.message:code);await execute({type:'run.update',...lease(),status:'blocked',reason:code});}catch{}
      }
    }finally{this.chatDrafts.delete(taskId);if(heartbeat)clearInterval(heartbeat);if(timeout)clearTimeout(timeout);if(run)await execute({type:'run.release',...lease()}).catch(()=>{});}
  }
  private async processActions(task:()=>Task,run:Run,signal:AbortSignal){
    for(const a of task().actions.filter(a=>a.kind==='github.issue.create'&&a.status==='proposed'&&a.runId===run.id)){
      signal.throwIfAborted();const approval=task().approvals.find(x=>x.actionId===a.id);if(approval?.decision!=='approved')continue;
      ensure(!this.hub.config.cloudUrl||this.hub.online,'offline_external_write');const token=await readSecret(`connector-${a.connectorId}`);ensure(token,'connector_auth_missing');
      const lease={taskId:task().id,runId:run.id,fencingToken:run.fencingToken};
      await this.hub.execute({type:'action.begin',...lease,actionId:a.id},'runner');
      try{const result=await new GitHubConnector(token).createIssue(a);await this.hub.execute({type:'action.result',...lease,actionId:a.id,outcome:'succeeded',...result},'runner');}
      catch{await this.hub.execute({type:'action.result',...lease,actionId:a.id,outcome:'unknown',externalId:null,resultUrl:null},'runner').catch(()=>{});throw new DomainError('external_result_unresolved');}
    }
  }
}
