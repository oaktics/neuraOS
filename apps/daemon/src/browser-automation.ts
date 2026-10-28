import {verifyBrowserCredential} from './browser-credentials.ts';
import type {FastifyInstance} from 'fastify';
import {z} from 'zod';
import {randomUUID} from 'node:crypto';
import {Fault,requireValue,type Workspace,type TerminalRecord} from './contracts.ts';
import type {Store} from './store.ts';

const uuid=z.uuid(), tabSchema=z.object({workspaceId:uuid,tabId:uuid,projectId:uuid,url:z.string().max(8192),title:z.string().max(2048),selected:z.boolean(),loading:z.boolean(),enabled:z.boolean()}).strict();
const target={workspaceId:uuid,tabId:uuid};
export const browserCommand=z.discriminatedUnion('action',[
  z.object({action:z.literal('list'),workspaceId:uuid.optional()}).strict(),
  ...(['snapshot','screenshot','stop'] as const).map(action=>z.object({action:z.literal(action),...target}).strict()),
  z.object({action:z.literal('navigate'),...target,url:z.string().max(8192).refine(value=>{try{if(value==='about:blank')return true;const u=new URL(value);return ['http:','https:'].includes(u.protocol)&&!u.username&&!u.password;}catch{return value==='about:blank';}})}).strict(),
  z.object({action:z.literal('click'),...target,ref:z.string().max(100)}).strict(),
  z.object({action:z.literal('fill'),...target,ref:z.string().max(100),text:z.string().max(10000)}).strict(),
  z.object({action:z.literal('key'),...target,ref:z.string().max(100),key:z.enum(['Enter','Tab','Escape','Backspace','ArrowUp','ArrowDown','ArrowLeft','ArrowRight'])}).strict(),
  z.object({action:z.literal('scroll'),...target,ref:z.string().max(100),x:z.number().min(-10000).max(10000),y:z.number().min(-10000).max(10000)}).strict(),
  z.object({action:z.literal('wait'),...target,text:z.string().min(1).max(1000),timeoutMs:z.number().int().min(100).max(15000).default(5000)}).strict(),
]);
type Tab=z.infer<typeof tabSchema>;
type Pending={id:string;deadline:number;projectId:string;terminalId:string;command:z.infer<typeof browserCommand>;sent:boolean;cancelled?:boolean;settled?:boolean;finish:(result:unknown,error?:string)=>void};
// No persisted page contents, images, form text or automatic mutation retries.
export function registerBrowserAutomation(app:FastifyInstance,store:Store,master:string){
  const instanceId=randomUUID();
  let nativeId='',lastPoll=0,tabs:Tab[]=[];
  const pending=new Map<string,Pending>();
  const workspace=(id:string)=>requireValue(store.get<Workspace>('workspaces',id),'workspace_missing','Workspace is unavailable.');
  const failAll=(error:string)=>{for(const p of pending.values())p.finish(undefined,error);};
  const timer=setInterval(()=>{if(Date.now()-lastPoll>3000){tabs=[];failAll('browser_disconnected');}for(const p of pending.values())if(p.deadline<Date.now())p.finish(undefined,'browser_timeout');},250);timer.unref();
  app.addHook('onClose',async()=>{clearInterval(timer);failAll('browser_disconnected');});
  app.post('/v1/browser/native/poll',{bodyLimit:12*1024*1024},async req=>{
    const body=z.object({nativeId:uuid,tabs:z.array(tabSchema).max(500),results:z.array(z.object({id:uuid,result:z.unknown().optional(),error:z.string().max(100).optional()}).strict()).max(32)}).strict().parse(req.body);
    if(nativeId&&nativeId!==body.nativeId&&Date.now()-lastPoll<3000)throw new Fault('browser_native_busy','Another app owns the browser bridge.',409);
    if(nativeId!==body.nativeId){failAll('browser_restarted');pending.clear();}
    nativeId=body.nativeId;lastPoll=Date.now();
    tabs=body.tabs.filter(t=>store.get<Workspace>('workspaces',t.workspaceId)?.projectId===t.projectId);
    for(const r of body.results){const p=pending.get(r.id);if(p){p.finish(r.result,r.error);pending.delete(r.id);}}
    for(const p of pending.values()){
      const caller=store.get<TerminalRecord>('terminals',p.terminalId);
      if(!caller||caller.status!=='running'||store.get<Workspace>('workspaces',caller.workspaceId)?.projectId!==p.projectId){p.finish(undefined,'browser_caller_inactive');continue;}
      if(p.command.action==='list')continue;
      const tab=tabs.find(t=>t.workspaceId===p.command.workspaceId&&t.tabId===('tabId' in p.command?p.command.tabId:''));
      if(!tab)p.finish(undefined,'browser_tab_closed');else if(!tab.enabled&&p.command.action!=='stop')p.finish(undefined,'browser_disabled');
    }
    const requests=[...pending.values()].filter(p=>!p.sent&&!p.cancelled&&p.deadline>Date.now()).map(p=>{p.sent=true;return {id:p.id,deadline:p.deadline,projectId:p.projectId,terminalId:p.terminalId,command:p.command};});
    return {instanceId,requests,cancelIds:[...pending.values()].filter(p=>p.cancelled).map(p=>p.id)};
  });
  app.post('/v1/browser/call',async req=>{
    const {terminalId,command}=z.object({terminalId:uuid,command:browserCommand}).strict().parse(req.body);
    if(!verifyBrowserCredential(master,terminalId,req.headers['x-neura-browser-token']))throw new Fault('browser_caller_unauthorized','Browser credential does not match the caller.',403);
    const caller=requireValue(store.get<TerminalRecord>('terminals',terminalId),'browser_caller_missing','A neuraOS terminal is required.');
    if(caller.status!=='running'||!['codex','claude'].includes(caller.provider))throw new Fault('browser_caller_inactive','The calling CLI is not running.',403);
    const projectId=workspace(caller.workspaceId).projectId;
    if(command.workspaceId&&workspace(command.workspaceId).projectId!==projectId)throw new Fault('browser_forbidden','Other projects are not accessible.',403);
    if(Date.now()-lastPoll>3000)throw new Fault('browser_disconnected','Browser app is not connected.',503);
    if(command.action==='list')return {currentWorkspaceId:caller.workspaceId,tabs:tabs.filter(t=>t.projectId===projectId&&(!command.workspaceId||t.workspaceId===command.workspaceId))};
    const tab=requireValue(tabs.find(t=>t.workspaceId===command.workspaceId&&t.tabId===command.tabId),'browser_tab_closed','Tab is closed or not mounted.');
    if(tab.projectId!==projectId)throw new Fault('browser_forbidden','Other projects are not accessible.',403);
    if(!tab.enabled&&command.action!=='stop')throw new Fault('browser_disabled','Resume browser access in the app.',409);
    const key=command.workspaceId+':'+command.tabId;
    if(command.action==='stop'){for(const p of pending.values())if(p.command.action!=='list'&&p.command.workspaceId===command.workspaceId&&'tabId' in p.command&&p.command.tabId===command.tabId)p.finish(undefined,'browser_cancelled');}
    else if([...pending.values()].some(p=>p.command.action!=='list'&&p.command.workspaceId+':'+('tabId' in p.command?p.command.tabId:'')===key))throw new Fault('browser_busy','Another request is operating this tab.',409);
    if(pending.size>=32)throw new Fault('browser_busy','Too many browser requests.',409);
    const id=randomUUID(),deadline=Date.now()+(command.action==='wait'?command.timeoutMs+2000:10000);
    return new Promise((resolve,reject)=>{
      pending.set(id,{id,deadline,projectId,terminalId,command,sent:false,finish:(result,error)=>{
        const p=pending.get(id);if(!p||p.settled)return;p.settled=true;
        // Keep a sent request quarantined until native confirms it has finished.
        // Timeout/disconnect cancels the caller promise, not the remote operation.
        if(error){p.cancelled=true;if(!p.sent)pending.delete(id);}
        if(error)reject(new Fault(error,'Browser operation stopped. Read the current state before retrying.',409));
        else resolve({workspaceId:command.workspaceId,tabId:command.tabId,result});
      }});
    });
  });
}
