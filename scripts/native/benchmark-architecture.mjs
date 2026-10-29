// Synthetic transport/storage slice, not full Fastify/PTY/CEF/provider measurement.
// Independent ephemeral loopback port and disposable DB under this worktree.
import {fileURLToPath} from 'node:url';
import {Store} from '../../apps/daemon/src/store.ts';
import {createServer} from 'node:http';
import {Worker} from 'node:worker_threads';
import {mkdtempSync,rmSync} from 'node:fs';
import {monitorEventLoopDelay} from 'node:perf_hooks';
const quantile=(a,p)=>[...a].sort((a,b)=>a-b)[Math.floor((a.length-1)*p)]??0;
const results=[];
for(const children of [1,5,10,20]){
 const dir=mkdtempSync(fileURLToPath(new URL('../../docs/architecture-evidence/tmp-',import.meta.url)));
 let store=new Store(`${dir}/isolated.sqlite`);let expected=0;
 let server,worker,producer,delay;
 try {
 for(let i=0;i<children;i++)store.put('terminals',{id:`t${i}`,status:'running'});
 server=createServer((req,res)=>{res.setHeader('content-type','application/json');const u=new URL(req.url,'http://localhost');res.end(JSON.stringify(u.pathname==='/state'?store.state():store.output(u.searchParams.get('id'),Number(u.searchParams.get('after')))));});
 await new Promise(r=>server.listen(0,'127.0.0.1',r));
 delay=monitorEventLoopDelay({resolution:10});delay.enable();const cpu=process.cpuUsage(),ru=process.resourceUsage(),start=performance.now();
 producer=setInterval(()=>{for(let i=0;i<children;i++){store.append(`t${i}`,`${expected}:`+'x'.repeat(1000)+'\n');expected++;}},10);
 worker=new Worker(`const {parentPort,workerData}=require('node:worker_threads');const samples=[],timers=[],pending=new Set();let timeouts=0,bytes=0;function poll(path,period){let cursor=0,busy=false;const timer=setInterval(()=>{if(busy)return;busy=true;const start=performance.now();const p=fetch(workerData.url+path+(path==='/state'?'':'&after='+cursor),{signal:AbortSignal.timeout(1000)}).then(async r=>{const s=await r.text();bytes+=Buffer.byteLength(s);const v=JSON.parse(s);if(v.cursor)cursor=v.cursor;samples.push(performance.now()-start);}).catch(()=>timeouts++).finally(()=>{busy=false;pending.delete(p)});pending.add(p);},period);timers.push(timer)}poll('/state',1000);for(let i=0;i<workerData.children;i++)poll('/output?id=t'+i,i===0?60:500);setTimeout(async()=>{timers.forEach(clearInterval);await Promise.all(pending);parentPort.postMessage({samples,timeouts,bytes});},5000);`,{eval:true,workerData:{url:`http://127.0.0.1:${server.address().port}`,children}});
 const metrics=await new Promise((resolve,reject)=>{worker.once('message',resolve);worker.once('error',reject)});
 clearInterval(producer);store.flushOutput();delay.disable();
 const rows=store.db.prepare('SELECT data FROM output ORDER BY sequence').all();
 const ids=rows.map(r=>Number(r.data.split(':',1)[0]));
 if(rows.length!==expected||ids.some((n,i)=>n!==i))throw Error('Output loss/order/duplicate');
 const used=process.cpuUsage(cpu),usage=process.resourceUsage();
 results.push({children,durationMs:performance.now()-start,chunks:expected,requests:metrics.samples.length,httpP95Ms:quantile(metrics.samples,.95),httpP99Ms:quantile(metrics.samples,.99),timeouts:metrics.timeouts,responseBytes:metrics.bytes,eventLoopP99Ms:delay.percentile(99)/1e6,eventLoopMaxMs:delay.max/1e6,cpuMs:(used.user+used.system)/1000,rssBytes:process.memoryUsage().rss,fsWrites:usage.fsWrite-ru.fsWrite,voluntaryContextSwitches:usage.voluntaryContextSwitches-ru.voluntaryContextSwitches,loss:0,duplicates:0});
 store.close();store=new Store(`${dir}/isolated.sqlite`);
 if(store.db.prepare('SELECT count(*) AS n FROM output').get().n!==expected)throw Error('Reopen lost committed rows');
 for(let i=0;i<children;i++){let cursor=0,text='';while(true){const page=store.output(`t${i}`,cursor);text+=page.data;cursor=page.cursor;if(!page.more)break;}const original=rows.filter((_,n)=>n%children===i).map(r=>r.data).join('');if(text!==original)throw Error('Cursor replay mismatch');}
 results.at(-1).reopenAndCursorReplay=true;
 } finally {
 clearInterval(producer);delay?.disable();await worker?.terminate();
 if(server?.listening)await new Promise(r=>server.close(r));
 store.close();rmSync(dir,{recursive:true});
 }
}
console.log(JSON.stringify({node:process.version,kind:'synthetic-http-store-slice',chunkBytes:1000,producerIntervalMs:10,durationPerCaseMs:5000,results},null,2));
