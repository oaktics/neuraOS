import {test} from 'node:test';
import assert from 'node:assert/strict';
import {createServer} from 'node:http';
import {WebSocketServer} from 'ws';
import {spawn} from 'node:child_process';
import {createInterface} from 'node:readline';
import {mkdtemp,writeFile,rm} from 'node:fs/promises';
import {once} from 'node:events';
const binary=process.env.NEURA_NATIVE_DAEMON;
const delay=ms=>new Promise(r=>setTimeout(r,ms));
const until=async check=>{for(let i=0;i<300;i++){if(check())return;await delay(10);}assert.fail('native MCP did not converge');};
test('native MCP 10/20/32 clients stay idle, deliver one channel event, replay state after reconnect and exit', {skip:!binary,timeout:60000},async t=>{
 for(const count of [10,20,32])await t.test(String(count),async()=>{
  const dir=await mkdtemp('/tmp/neura-native-mcp-');await writeFile(dir+'/token','fixture');
  let requests=0,revision=1,connections=0;const pending=new Map(),commands=[];
  const server=createServer(async(req,res)=>{requests++;assert.equal(req.headers.authorization,'Bearer fixture');let text='';for await(const chunk of req)text+=chunk;let value={};
   if(req.url==='/v1/agents')value={agents:[],revision,currentSessionIds:{}};
   else if(req.url.endsWith('/channel')){assert.equal(req.headers['x-neura-channel-token'],'channel');const terminal=req.url.split('/')[3];value=pending.get(terminal)??{};pending.delete(terminal);}
   else if(req.url==='/v1/commands'){commands.push(JSON.parse(text));value={ok:true};}
   else if(req.url==='/v1/state')value={projects:[],workspaces:[],terminals:[]};
   res.writeHead(200,{'content-type':'application/json'});res.end(JSON.stringify(value));
  });const ws=new WebSocketServer({noServer:true});server.on('upgrade',(req,socket,head)=>{assert.equal(req.headers.authorization,'Bearer fixture');connections++;ws.handleUpgrade(req,socket,head,client=>client.send(JSON.stringify({type:'ready',epoch:'fixture'})));});
  await new Promise(r=>server.listen(0,'127.0.0.1',r));const url=`http://127.0.0.1:${server.address().port}`;
  const clients=Array.from({length:count},(_,i)=>{
   const process_=spawn(binary,['mcp'],{env:{...process.env,NEURA_SUPERVISION_URL:url,NEURA_SUPERVISION_TOKEN_FILE:dir+'/token',NEURA_SUPERVISION_TERMINAL:String(i),NEURA_SUPERVISION_WORKSPACE:'w',NEURA_SUPERVISION_CHANNEL:'claude',NEURA_CHANNEL_TOKEN:'channel'},stdio:['pipe','pipe','pipe']});let stderr='';process_.stderr.on('data',b=>stderr+=b);const messages=[],waiters=new Map();let next=0;
   createInterface({input:process_.stdout}).on('line',line=>{const m=JSON.parse(line);if(m.id!==undefined){waiters.get(m.id)?.(m);waiters.delete(m.id);}else messages.push(m);});
   const rpc=(method,params={})=>new Promise(resolve=>{const id=++next;waiters.set(id,resolve);process_.stdin.write(JSON.stringify({jsonrpc:'2.0',id,method,params})+'\n');});
   return {process:process_,messages,rpc,stderr:()=>stderr};
  });
  const change=(agentTerminals)=>{for(const client of ws.clients)client.send(JSON.stringify({type:'changed',state:true,terminals:[],...(agentTerminals?{agentTerminals}:{})}));};
  try{
   await Promise.all(clients.map(async c=>{const init=await c.rpc('initialize');assert.ok(init.result.capabilities.experimental['claude/channel']);c.process.stdin.write(JSON.stringify({jsonrpc:'2.0',method:'notifications/initialized'})+'\n');}));
   await until(()=>connections===count);await delay(300);const idle=requests;await delay(1600);assert.equal(requests,idle,'healthy idle bridge makes zero HTTP requests');
   const tools=(await clients[0].rpc('tools/list')).result.tools;for(const name of ['task_list','task_read','task_wait','task_watch','task_report','task_ack','task_start','task_spawn','task_send','task_interrupt','task_respond','workspace_create','workspace_delete','workspace_list','browser_screenshot','channel_ack'])assert.ok(tools.some(t=>t.name===name),name);
   assert.equal(tools.find(t=>t.name==='task_watch').inputSchema.properties.taskIds.maxItems,undefined);
   const beforeTarget=requests;pending.set('0',{content:'exactly once',meta:{kind:'instruction',task_id:'fixture'}});revision++;change(['0']);await until(()=>clients[0].messages.length===1);await delay(100);assert.equal(requests-beforeTarget,1,'one targeted change wakes only its MCP');const beforeOther=requests;change([]);await delay(100);assert.equal(requests,beforeOther,'unrelated state does not wake Channels');change(['0']);await delay(100);assert.equal(clients[0].messages.length,1);
   const waiting=clients.map(c=>c.rpc('tools/call',{name:'task_wait',arguments:{after:revision}}));await delay(100);revision++;change();for(const reply of await Promise.all(waiting))assert.equal(JSON.parse(reply.result.content[0].text).revision,revision);
   const before=connections;for(const socket of ws.clients)socket.terminate();await until(()=>connections===before+count);await delay(200);assert.equal(clients[0].messages.length,1,'reconnect does not replay consumed channel instructions');
   const ends=clients.map(c=>once(c.process,'exit'));clients.forEach(c=>c.process.stdin.end());for(const ended of await Promise.all(ends))assert.equal(ended[0],0);assert.ok(clients.every(c=>!c.stderr()));
   t.diagnostic(`${count} native MCPs: idle HTTP 0/1.6s vs prior >=${count*2}; state wake, channel dedup, reconnect and EOF verified`);
  }finally{clients.forEach(c=>c.process.kill());for(const c of ws.clients)c.terminate();await new Promise(r=>ws.close(r));await new Promise(r=>server.close(r));await rm(dir,{recursive:true,force:true});}
 });
});
