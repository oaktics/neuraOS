import {ensure} from '../../policy/src/index.ts';
import {cliPath} from '../../adapters/local-auth.ts';
import type {WorkspaceManager} from './manager.ts';
import type {Terminals} from './terminal.ts';
export interface Engineer {id:string;projectId:string;title:string;provider:'codex'|'claude';objective:string;createdAt:string}
export function engineerCommand(provider:'codex'|'claude',id:string,objective:string,resume=false){
 if(provider==='codex')return [...(resume?['resume','--last']:[]),'--sandbox','workspace-write','--ask-for-approval','on-request','-c','approvals_reviewer="user"',...(resume||!objective?[]:['--',objective])];
 return ['--permission-mode','manual',...(resume?['--resume',id]:['--session-id',id]),...(resume||!objective?[]:['--',objective])];
}
/** Runs the installed interactive CLI unchanged. Permission prompts stay in its PTY. */
export class Engineers {
 private locks=new Map<string,Promise<unknown>>();
 constructor(readonly workspace:WorkspaceManager,readonly terminals:Terminals,private resolveCLI=cliPath){}
 records():Engineer[]{return JSON.parse(this.workspace.store.meta('native-engineers')??'[]');}
 list(projectId:string){return this.records().filter(e=>e.projectId===projectId).map(e=>({...e,terminalId:this.terminals.activeId(projectId,e.id),status:this.terminals.activeId(projectId,e.id)?'running':'stopped'}));}
 async start(input:Engineer,maxWorkers:number,resume=false){
  const previous=this.locks.get(input.projectId)??Promise.resolve();
  const result=previous.catch(()=>{}).then(async()=>{
   const existing=this.records().find(e=>e.id===input.id);
   if(existing)ensure(existing.projectId===input.projectId&&existing.provider===input.provider,'engineer_scope');
   const record=existing??input,active=this.terminals.activeId(record.projectId,record.id);if(active)return {...record,terminalId:active};
   ensure(!existing||resume,'engineer_stopped','この社員は停止済みです。「再開」を選んでください。');
   ensure(this.list(record.projectId).filter(e=>e.terminalId).length<maxWorkers,'engineer_limit');
   const executable=await this.resolveCLI(record.provider);ensure(executable,'provider_unavailable');
   await this.workspace.createWorktree(record.projectId,record.id);
   const terminal=this.terminals.open(record.projectId,record.id,this.workspace.root(record.projectId,record.id),{file:executable,args:engineerCommand(record.provider,record.id,record.objective,!!existing)});
   if(!existing)this.workspace.store.setMeta('native-engineers',JSON.stringify([...this.records(),record]));
   return {...record,terminalId:terminal.id};
  });this.locks.set(input.projectId,result);try{return await result;}finally{if(this.locks.get(input.projectId)===result)this.locks.delete(input.projectId);}
 }
}
