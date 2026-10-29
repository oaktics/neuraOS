// Synthetic provider wire peer. Never loads credentials or contacts a model API.
import assert from 'node:assert/strict';
import {createConnection} from 'node:net';
import {createInterface} from 'node:readline';
import {randomUUID} from 'node:crypto';
import {appendFileSync} from 'node:fs';
import {join} from 'node:path';
import WebSocket,{WebSocketServer} from 'ws';
const [provider,...args]=process.argv.slice(2);
if(args.includes('--help')){console.log('--remote app-server --mcp-config --append-system-prompt --settings');process.exit(0);}
if(args.includes('--version')){console.log('2.1.312 fixture');process.exit(0);}
appendFileSync(join(process.env.HOME,'fixture-processes.jsonl'),JSON.stringify({pid:process.pid,provider,role:args[0]==='app-server'?'app-server':'pty'})+'\n');
const value=flag=>args[args.indexOf(flag)+1];
if(provider==='codex'&&args[0]==='app-server'){
 const socket=value('--listen').replace('unix://','');
 const wss=new WebSocketServer({noServer:true});
 // ws handles HTTP Upgrade over the Unix listener through an HTTP server instead.
 const {createServer:httpServer}=await import('node:http');const http=httpServer();
 http.on('upgrade',(req,sock,head)=>wss.handleUpgrade(req,sock,head,ws=>wss.emit('connection',ws)));
 let thread,turn;
 const publish=(method,params)=>{for(const ws of wss.clients)if(ws.readyState===WebSocket.OPEN)ws.send(JSON.stringify({method,params}));};
 wss.on('connection',ws=>ws.on('message',raw=>{
  const m=JSON.parse(raw);let result={};
  if(m.method==='thread/start'||m.method==='thread/resume'){thread={id:m.params.threadId??randomUUID(),cwd:m.params.cwd,name:'fixture Codex',status:{type:'idle'}};result={thread};}
  else if(m.method==='thread/loaded/list')result={data:thread?[thread.id]:[]};
  else if(m.method==='thread/read')result={thread};
  else if(m.method==='fixture/input'){
   const data=m.params.data;
   if(data==='work'){turn=randomUUID();publish('turn/started',{threadId:thread.id,turn:{id:turn}});}
   if(data==='done'){publish('turn/completed',{threadId:thread.id,turn:{id:turn,status:'completed'}});}
  }
  // No title inference: reject this optional model call explicitly.
  else if(m.method==='turn/start'){if(m.id!==undefined)ws.send(JSON.stringify({id:m.id,error:{code:-32000,message:'fixture has no model'}}));return;}
  if(m.id!==undefined)ws.send(JSON.stringify({id:m.id,result}));
 }));
 await new Promise(r=>http.listen(socket,r));
}else{
 let emit=async()=>{},remote;
 if(provider==='claude'){
  assert.ok(args.includes('--settings'));assert.ok(args.includes('--mcp-config'));
  const config=JSON.parse(value('--mcp-config'));assert.ok(config.mcpServers.neuraos.command);
  const session=randomUUID();
  emit=async event=>{const s=createConnection(process.env.NEURA_ACTIVITY_SOCKET);await new Promise((r,j)=>{s.once('connect',r);s.once('error',j)});s.end(JSON.stringify({hook_event_name:event,session_id:session,cwd:process.cwd(),source:'startup'})+'\n');await new Promise(r=>s.once('close',r));};
  await emit('SessionStart');
 }else{
  assert.equal(args[0],'resume');assert.ok(args.includes('--remote'));
  remote=new WebSocket('ws://localhost/',{createConnection:()=>createConnection(value('--remote').replace('unix://',''))});
  await new Promise((r,j)=>{remote.once('open',r);remote.once('error',j)});
  emit=async event=>remote.send(JSON.stringify({method:'fixture/input',params:{data:event}}));
 }
 console.log(`FIXTURE_READY:${provider}`);
 const lines=createInterface({input:process.stdin});let sequence=Promise.resolve();
 lines.on('line',line=>{sequence=sequence.then(async()=>{
  if(line==='exit'){if(provider==='claude')await emit('SessionEnd');remote?.close();console.log('FIXTURE_EXIT');process.exit(0);}
  if(line==='work')await emit(provider==='claude'?'UserPromptSubmit':'work');
  if(line==='done')await emit(provider==='claude'?'Stop':'done');
  console.log(`FIXTURE_ACK:${line}:日本語😀`);
 }).catch(e=>{console.error(e.message);process.exit(1);});});
}
