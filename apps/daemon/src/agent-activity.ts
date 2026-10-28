import {execFile} from 'node:child_process';
import {promisify} from 'node:util';
import {mkdtemp,rm} from 'node:fs/promises';
import {createServer,type Socket} from 'node:net';
import {join} from 'node:path';
import {fileURLToPath} from 'node:url';
import type {AgentActivity,Provider} from './contracts.ts';

export interface ActivityEvent {
  hook_event_name?:string; session_id?:string; transcript_path?:string; agent_id?:string;
  turn_id?:string; tool_name?:string; tool_use_id?:string; source?:string; notification_type?:string;
}

// Activity is driven by lifecycle events, never by output frequency or keystrokes.
export class ActivityTracker {
  activity:AgentActivity='unknown';
  notification?:'waiting'|'completed';
  private session?:string;
  get sessionId(){return this.session;}
  private transcript?:string;
  private turn?:string;
  private waiting=new Set<string>();
  interrupt(){this.waiting.clear();this.activity='unknown';}
  accept(event:ActivityEvent):AgentActivity {
    this.notification=undefined;
    if(event.agent_id)return this.activity;
    const name=event.hook_event_name;
    if(name==='SessionStart'){
      if(this.session&&event.source==='startup'&&this.activity!=='idle'&&this.activity!=='unknown')return this.activity;
      // Subagent transcripts must not change the parent terminal's indicator.
      if(this.transcript&&event.transcript_path!==this.transcript&&!['clear','resume','fork'].includes(event.source??''))return this.activity;
      this.session=event.session_id;this.transcript=event.transcript_path;this.waiting.clear();
      this.activity=event.source==='compact'?'working':'idle';return this.activity;
    }
    if(this.session&&event.session_id!==this.session)return this.activity;
    if(this.transcript&&event.transcript_path!==this.transcript)return this.activity;
    if(this.turn&&event.turn_id&&event.turn_id!==this.turn&&name!=='UserPromptSubmit')return this.activity;
    const previous=this.activity;
    const key=event.tool_use_id??event.tool_name??'permission';
    switch(name){
      case 'UserPromptSubmit':this.turn=event.turn_id;this.waiting.clear();this.activity='working';break;
      case 'PreCompact':case 'PostCompact':this.activity=this.waiting.size?'waiting':'working';break;
      case 'PreToolUse':
        if(['AskUserQuestion','request_user_input','ExitPlanMode'].includes(event.tool_name?.split('.').at(-1)??''))this.waiting.add(key);
        this.activity=this.waiting.size?'waiting':'working';break;
      case 'PermissionRequest':this.waiting.add(key);this.activity='waiting';break;
      case 'Elicitation':this.waiting.add('elicitation');this.activity='waiting';break;
      case 'ElicitationResult':this.waiting.delete('elicitation');this.activity=this.waiting.size?'waiting':'working';break;
      case 'PostToolUse':case 'PostToolUseFailure':
        this.waiting.delete(key);if(event.tool_name)this.waiting.delete(event.tool_name);this.waiting.delete('notification');
        this.activity=this.waiting.size?'waiting':'working';break;
      case 'Notification':
        if(['permission_prompt','elicitation_dialog'].includes(event.notification_type??'')){this.waiting.add('notification');this.activity='waiting';}
        break;
      case 'Stop':case 'Interrupt':this.waiting.clear();this.activity='idle';break;
      case 'StopFailure':this.interrupt();break;
      case 'SessionEnd':this.interrupt();this.session=undefined;this.transcript=undefined;this.turn=undefined;break;
    }
    if(this.activity==='waiting'&&previous!=='waiting')this.notification='waiting';
    if(name==='Stop'&&(previous==='working'||previous==='waiting'))this.notification='completed';
    return this.activity;
  }
}

const quoteShell=(value:string)=>"'"+value.replaceAll("'","'\\''")+"'";
const command=()=>`${quoteShell(process.execPath)} ${quoteShell(fileURLToPath(new URL('./agent-activity-hook.mjs',import.meta.url)))}`;
export function activityArguments(provider:Provider,hookCommand=command()):string[]{
  if(provider==='shell')return [];
  const events=['SessionStart','SessionEnd','UserPromptSubmit','PreToolUse','PermissionRequest','PostToolUse','Stop','PreCompact'];
  events.push(...(provider==='codex'?['Interrupt','PostCompact']:['PostToolUseFailure','Notification','StopFailure','Elicitation','ElicitationResult']));
  const hooks=Object.fromEntries(events.map(event=>[event,[{hooks:[{type:'command',command:hookCommand,timeout:1}]}]]));
  if(provider==='claude')return ['--settings',JSON.stringify({hooks})];
  // Inline session config layers add to user/project hooks. Do not alter hook
  // trust, global settings, authentication, or the user's existing hooks.
  // A private server keeps this terminal's hook environment out of shared sessions.
  return ['--no-daemon',...Object.entries(hooks).flatMap(([event,entries])=>[
    '-c',`hooks.${event}=[{ hooks = [{ type = "command", command = ${JSON.stringify(entries[0].hooks[0].command)}, timeout = 1 }] }]`,
  ])];
}

const supported=new Map<string,Promise<boolean>>();
export async function supportsActivity(provider:Provider,program:string):Promise<boolean>{
  if(provider==='shell')return false;
  const key=provider+':'+program;
  let result=supported.get(key);
  if(!result){
    result=promisify(execFile)(program,['--help'],{timeout:3000,maxBuffer:256*1024})
      .then(async({stdout})=>{
        if(provider==='codex')return stdout.includes('--no-daemon')&&stdout.includes('--dangerously-bypass-hook-trust');
        if(!stdout.includes('--settings'))return false;
        // Older Claude settings validators reject unknown lifecycle event keys.
        // Only inject the full hook set into the version family verified here.
        const version=await promisify(execFile)(program,['--version'],{timeout:3000,maxBuffer:4096});
        const match=version.stdout.match(/^(\d+)\.(\d+)\.(\d+)/);
        if(!match)return false;
        const [major,minor,patch]=match.slice(1).map(Number);
        return major>2||(major===2&&(minor>1||(minor===1&&patch>=306)));
      })
      .catch(()=>false);
    supported.set(key,result);
  }
  return result;
}

export interface ActivityBridge {path:string;close:()=>Promise<void>}
export async function activityBridge(onEvent:(event:ActivityEvent)=>void):Promise<ActivityBridge>{
  // /tmp keeps AF_UNIX paths below macOS's 104-byte limit even with long home paths.
  // mkdtemp creates a private 0700 directory; each terminal has its own socket.
  const directory=await mkdtemp('/tmp/neura-activity-'),path=join(directory,'events.sock');
  const sockets=new Set<Socket>();
  const server=createServer(socket=>{
    sockets.add(socket);let data='';
    socket.setEncoding('utf8');socket.setTimeout(1000,()=>socket.destroy());
    socket.on('error',()=>socket.destroy());socket.on('close',()=>sockets.delete(socket));
    socket.on('data',chunk=>{
      data+=chunk;
      if(data.length>16384){socket.destroy();return;}
      const newline=data.indexOf('\n');if(newline<0)return;
      try{
        const event=JSON.parse(data.slice(0,newline));
        if(event&&typeof event==='object'&&!Array.isArray(event)&&Object.values(event).every(value=>typeof value==='string'))onEvent(event);
      }catch{}
      socket.end();socket.removeAllListeners('data');
    });
  });
  server.maxConnections=16;
  try {await new Promise<void>((resolve,reject)=>{server.once('error',reject);server.listen(path,()=>{server.removeListener('error',reject);resolve();});});}
  catch(error){await rm(directory,{recursive:true,force:true});throw error;}
  server.on('error',()=>{});
  return {path,close:async()=>{
    for(const socket of sockets)socket.destroy();
    await new Promise<void>(resolve=>server.close(()=>resolve()));
    await rm(directory,{recursive:true,force:true});
  }};
}
