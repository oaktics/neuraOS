// End-to-end loopback HTTP/PTY/durable replay benchmark in disposable data dirs.
// Does not use the installed app, real providers, credentials or project state.
import {spawn} from 'node:child_process';
import {mkdtemp,writeFile,readFile,rm,realpath} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join,resolve} from 'node:path';
import {createServer} from 'node:net';
import {randomUUID} from 'node:crypto';
import {setTimeout as sleep} from 'node:timers/promises';
import {performance} from 'node:perf_hooks';
import WebSocket from 'ws';
const counts=(process.env.NEURA_BENCH_COUNTS??'10,20,32').split(',').map(Number);
const rows=Number(process.env.NEURA_BENCH_ROWS??256),payloadSize=2048;
const command=process.env.NEURA_BENCH_COMMAND?JSON.parse(process.env.NEURA_BENCH_COMMAND):[resolve('crates/native-core/target/release/neura-native-core')];
const legacy=process.argv.includes('--legacy');
const percentile=(values,p)=>[...values].sort((a,b)=>a-b)[Math.min(values.length-1,Math.floor(values.length*p))]??0;
const freePort=async()=>{const s=createServer();await new Promise((r,j)=>{s.once('error',j);s.listen(0,'127.0.0.1',r)});const port=s.address().port;await new Promise(r=>s.close(r));return port;};
class Pulse {pending=false;wake;signal(){this.pending=true;this.wake?.();}async wait(){if(this.pending){this.pending=false;return;}await new Promise(r=>this.wake=r);this.wake=undefined;this.pending=false;}}
const results=[];
for(const children of counts){
 const directory=await mkdtemp(join(tmpdir(),'neura-native-load-')),port=await freePort(),url=`http://127.0.0.1:${port}`;
 const projectPath=join(directory,'project');await import('node:fs/promises').then(fs=>fs.mkdir(projectPath));const project=await realpath(projectPath);
 const producer=join(project,'producer.py');
 await writeFile(producer,`import sys,time\nidentity=sys.argv[1]\nfor row in range(${rows}):\n sys.stdout.write('NEURA_ROW:'+identity+':'+str(row)+':'+'x'*${payloadSize}+':日本語:END\\n')\n sys.stdout.flush()\n if row%16==0: time.sleep(0.005)\n`);
 let child,token,socket,exitPromise,output='',failed=false,stateTask;let changes=0,ready=0,stopping=false;const records=new Map(),latencies=[],inputLatencies=[];let httpErrors=0;const headers=()=>({authorization:`Bearer ${token}`,'content-type':'application/json'});
 const request=async(path,body,timeout=15000)=>{const start=performance.now();const response=await fetch(url+path,{method:body?'POST':'GET',headers:headers(),body:body?JSON.stringify(body):undefined,signal:AbortSignal.timeout(timeout)});const v=await response.json();if(!response.ok){httpErrors++;throw Error(`${path}: ${response.status} ${v.error}`);}return {value:v,elapsed:performance.now()-start};};
 const execute=async(c)=>request('/v1/commands',{operationId:randomUUID(),command:c});
 const launch=async()=>{
  output='';child=spawn(command[0],command.slice(1),{cwd:process.cwd(),env:{...process.env,NEURA_DEV_DATA_DIR:directory,NEURA_DEV_PORT:String(port)},stdio:['ignore','pipe','pipe'],detached:true});
  child.stdout.on('data',b=>output=(output+b).slice(-16000));child.stderr.on('data',b=>output=(output+b).slice(-16000));
  exitPromise=new Promise(r=>child.once('exit',(code,signal)=>r({code,signal})));child.once('error',()=>{});
  for(let i=0;i<200;i++){try{token=(await readFile(join(directory,'daemon-token'),'utf8')).trim();const state=(await request('/v1/state',undefined,1000)).value;if(state.protocolVersion===1)return state;}catch{}if(child.exitCode!==null)throw Error(`Daemon exited: ${output}`);await sleep(50);}throw Error(`Daemon startup timed out: ${output}`);
 };
 const stop=async()=>{socket?.close();child.kill('SIGTERM');const result=await Promise.race([exitPromise,sleep(10000).then(()=>null)]);if(!result){process.kill(-child.pid,'SIGKILL');await exitPromise;throw Error('Daemon did not stop cleanly');}if(result.code!==0)throw Error(`Daemon shutdown: ${JSON.stringify(result)} ${output}`);};
 const stream=async()=>{
  socket=new WebSocket(url.replace('http:','ws:')+'/v1/stream',{headers:headers()});
  await new Promise((resolve,reject)=>{const timer=setTimeout(()=>reject(Error('No stream ready')),5000);socket.on('error',reject);socket.on('message',bytes=>{const change=JSON.parse(bytes);if(change.type==='ready'){ready++;for(const r of records.values())r.pulse.signal();clearTimeout(timer);resolve();}else if(change.type==='changed'){changes++;for(const id of change.terminals??[])records.get(id)?.pulse.signal();}});});
 };
 const drain=async record=>{for(;;){const {value}=await request(`/v1/terminals/${record.id}/output?after=${record.cursor}&chunksOnly=true`);record.text+=(value.chunks??[]).map(c=>c.data).join('');record.cursor=value.cursor;record.status=value.status;if(!value.more)return;}};
 try{
  const initial=await launch();if(!legacy&&!initial.features?.includes('state.stream'))throw Error('Native daemon does not advertise state.stream');
  if(!legacy)await stream();
  const added=(await execute({type:'project.add',path:project})).value;
  const state=(await request('/v1/state')).value;
  const workspace=state.workspaces.find(w=>w.path===project)??state.workspaces.find(w=>w.projectId===added.project?.id);
  if(!workspace)throw Error('Fixture workspace missing');
  const terminals=await Promise.all(Array.from({length:children},()=>execute({type:'terminal.open',workspaceId:workspace.id,provider:'shell',resume:false})));
  const snapshot=(await request('/v1/state')).value;const ids=snapshot.terminals.filter(t=>t.workspaceId===workspace.id).map(t=>t.id);if(ids.length!==children)throw Error(`Expected ${children} terminals, got ${ids.length}`);
  for(const [index,id]of ids.entries())records.set(id,{id,index,cursor:0,text:'',status:'running',pulse:new Pulse()});
  stateTask=(async()=>{while(!stopping){const r=await request('/v1/state');latencies.push(r.elapsed);await sleep(50);}})();
  const start=performance.now();
  const readers=[...records.values()].map(async r=>{while(r.status==='running'){await drain(r);if(r.status!=='running')break;if(legacy)await sleep(r.index===0?60:500);else {let timer;try{await Promise.race([r.pulse.wait(),new Promise((_,reject)=>{timer=setTimeout(()=>reject(Error(`No terminal event ${r.index}`)),15000)})]);}finally{clearTimeout(timer);}}}await drain(r);});
  await Promise.all([...records.values()].map(async r=>{const response=await execute({type:'terminal.input',terminalId:r.id,clientId:randomUUID(),data:`/usr/bin/python3 '${producer}' ${r.index}; exit\n`});inputLatencies.push(response.elapsed);}));
  await Promise.all(readers);stopping=true;await stateTask;stateTask=undefined;
  for(const r of records.values()){
   const matches=[...r.text.matchAll(/NEURA_ROW:(\d+):(\d+):(x+):日本語:END/g)];
   if(matches.length!==rows||matches.some((m,i)=>Number(m[1])!==r.index||Number(m[2])!==i||m[3].length!==payloadSize))throw Error(`PTY loss/order/UTF8 corruption terminal ${r.index}: ${matches.length}/${rows}`);
  }
  const duration=performance.now()-start;const saved=new Map([...records].map(([id,r])=>[id,r.text]));
  const idleBefore=changes;await sleep(1000);const idleChanges=changes-idleBefore;
  // Deliberate stream reconnect must produce ready then permit cursor recovery.
  if(!legacy){socket.close();await stream();}
  await stop();await launch();
  for(const r of records.values()){r.cursor=0;r.text='';await drain(r);if(r.text!==saved.get(r.id))throw Error('Durable cursor replay differs after restart');}
  await stop();child=undefined;
  results.push({children,rowsPerTerminal:rows,bytesPerRow:payloadSize,durationMs:duration,httpStateP95Ms:percentile(latencies,.95),httpStateP99Ms:percentile(latencies,.99),inputP99Ms:percentile(inputLatencies,.99),httpErrors,changeMessages:changes,streamReady:ready,idleChanges,loss:0,duplicates:0,unicodeIntact:true,restartReplay:true});
 }catch(e){failed=true;throw e;}finally{
  stopping=true;await stateTask?.catch(()=>{});socket?.terminate();if(child&&child.exitCode===null){await Promise.allSettled([...records.keys()].map(terminalId=>execute({type:'terminal.stop',terminalId})));try{await stop();}catch{try{process.kill(-child.pid,'SIGKILL');}catch{}await exitPromise;}}
  // Preserve failing isolated evidence; never touch installed app data.
  if(failed)console.error(`Benchmark evidence retained: ${directory}`);else await rm(directory,{recursive:true,force:true});
 }
}
console.log(JSON.stringify({kind:legacy?'legacy-daemon-pty-http':'native-daemon-pty-stream',realProvider:false,realBatteryMeasurement:false,results},null,2));
