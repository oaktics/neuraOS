import {spawn,execFileSync,type ChildProcess} from 'node:child_process';
import {mkdir,writeFile,readFile,stat,rm} from 'node:fs/promises';
import {join,resolve} from 'node:path';
import {randomUUID} from 'node:crypto';
import assert from 'node:assert/strict';

export type SmokeWorkspace={id:string;projectId:string};
export type SmokeTerminal={id:string;workspaceId:string;[key:string]:unknown};
export const credentialFile=(data:string)=>join(data,'fixture-browser-credential.json');
const quote=(text:string)=>"'"+text.replaceAll("'","'\\''")+"'";
async function waitFor<T>(description:string,read:()=>Promise<T|undefined>,child:ChildProcess):Promise<T>{
 const deadline=Date.now()+30000;
 while(Date.now()<deadline){
  if(child.exitCode!==null||child.signalCode!==null)throw Error(`Fixture daemon exited while waiting for ${description}`);
  const value=await read();if(value!==undefined)return value;
  await new Promise(r=>setTimeout(r,100));
 }
 throw Error(`Timed out waiting for ${description}`);
}

// The fake provider only captures the credential delivered to its own legitimate
// launch. Never add an endpoint that issues test credentials to production.
export async function startExternalSmokeDaemon(data:string,port:number,onChild:(child:ChildProcess)=>void){
 const executable=resolve(process.env.NEURA_BROWSER_SMOKE_DAEMON!);
 const extra:unknown=JSON.parse(process.env.NEURA_BROWSER_SMOKE_DAEMON_ARGS??'[]');
 assert(Array.isArray(extra)&&extra.every(arg=>typeof arg==='string'),'daemon args must be a JSON string array');
 const capture=credentialFile(data),provider=join(data,'fixture-claude'),script=provider+'.mjs';
 await rm(capture,{force:true});
 await writeFile(script,`import {writeFileSync} from 'node:fs';
const args=process.argv.slice(2);
if(args.includes('--help')) {console.log('--mcp-config --append-system-prompt --settings --dangerously-load-development-channels');process.exit(0);}
if(args.includes('--version')) {console.log('2.1.312 (fixture)');process.exit(0);}
const index=args.indexOf('--mcp-config');
if(index<0)process.exit(2);
const server=JSON.parse(args[index+1]).mcpServers.neuraos;
const env=server.env;
if(!env.NEURA_BROWSER_TOKEN||!env.NEURA_SUPERVISION_TERMINAL||!env.NEURA_SUPERVISION_WORKSPACE)process.exit(3);
writeFileSync(${JSON.stringify(capture)},JSON.stringify({token:env.NEURA_BROWSER_TOKEN,terminalId:env.NEURA_SUPERVISION_TERMINAL,workspaceId:env.NEURA_SUPERVISION_WORKSPACE,command:server.command,args:server.args}),{mode:0o600,flag:'wx'});
process.stdin.resume();
const timer=setInterval(()=>{},60000);
for(const signal of ['SIGTERM','SIGINT','SIGHUP'])process.once(signal,()=>{clearInterval(timer);process.exit(0);});
`,{mode:0o600});
 await writeFile(provider,`#!/bin/sh\nexec ${quote(process.execPath)} ${quote(script)} "$@"\n`,{mode:0o700});
 const child=spawn(executable,extra,{env:{...process.env,NEURA_DEV_DATA_DIR:data,NEURA_DEV_PORT:String(port),NEURA_CLAUDE_PATH:provider},stdio:['ignore','pipe','pipe']});
 onChild(child);
 // Keep secrets out of logs/evidence. Only use this isolated daemon's token file.
 const token=await waitFor('daemon token',async()=>{try{return (await readFile(join(data,'daemon-token'),'utf8')).trim()||undefined;}catch{return undefined;}},child);
 const endpoint=`http://127.0.0.1:${port}`;
 const request=async(path:string,command?:unknown)=>{
  const response=await fetch(endpoint+path,{method:command?'POST':'GET',headers:{authorization:`Bearer ${token}`,...(command?{'content-type':'application/json'}:{})},...(command?{body:JSON.stringify({operationId:randomUUID(),command})}:{}),signal:AbortSignal.timeout(10000)});
  if(!response.ok)throw Error(`Fixture API ${path}: HTTP ${response.status} ${await response.text()}`);
  return response.json() as Promise<any>;
 };
 await waitFor('authenticated state',async()=>{try{return await request('/v1/state');}catch{return undefined;}},child);
 const command=(value:unknown)=>request('/v1/commands',value);
 // Use public commands for real registered workspaces, including same-project
 // and foreign-project tabs. This is a disposable repository, never the user's.
 const repository=join(data,'fixture-repository');await mkdir(repository,{recursive:true});
 execFileSync('git',['init','-b','main',repository],{stdio:'ignore'});
 execFileSync('git',['-C',repository,'-c','commit.gpgsign=false','-c','core.hooksPath=/dev/null','-c','user.name=Browser Fixture','-c','user.email=fixture@example.invalid','commit','--allow-empty','-m','Browser smoke fixture'],{stdio:'ignore'});
 const project=await command({type:'project.add',path:repository});
 const state=await request('/v1/state');
 const primary=state.workspaces.find((w:any)=>w.projectId===project.id&&(w.kind==='root'||w.kind==='folder'));
 assert(primary,'project.add must create a root workspace');
 const secondary=await command({type:'workspace.create',projectId:project.id,name:'Hidden browser fixture',baseRef:'HEAD',skipStartup:true});
 const otherFolder=join(data,'foreign-project');await mkdir(otherFolder,{recursive:true});
 const other=await command({type:'project.add',path:otherFolder});
 const otherState=await request('/v1/state');
 const foreign=otherState.workspaces.find((w:any)=>w.projectId===other.id);
 assert(foreign,'foreign project must have a workspace');
 const terminal=await command({type:'terminal.open',workspaceId:primary.id,provider:'claude'});
 const captured=await waitFor('managed Claude MCP credential',async()=>{try{return JSON.parse(await readFile(capture,'utf8'));}catch{return undefined;}},child);
 assert.equal((await stat(capture)).mode&0o777,0o600,'credential fixture must be private');
 assert.equal(captured.terminalId,terminal.id,'credential must belong to the launched terminal');
 assert.equal(captured.workspaceId,primary.id,'credential must be scoped to the fixture workspace');
 assert.equal(typeof captured.token,'string');assert(captured.token.length>0);
 assert.equal(typeof captured.command,'string');assert(Array.isArray(captured.args)&&captured.args.every((arg:unknown)=>typeof arg==='string'));
 return {mcpLaunch:{command:captured.command as string,args:captured.args as string[]},token,browserToken:captured.token as string,workspaces:[primary,secondary,foreign] as SmokeWorkspace[],terminal:terminal as SmokeTerminal,request};
}
