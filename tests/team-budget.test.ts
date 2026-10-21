import {test} from 'node:test';
import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {setup,input,runner,startTime} from './helpers.ts';
import {reviewReserve,turnAllowance} from '../packages/task-domain/src/budget.ts';
import {TokenMeter} from '../packages/adapters/token-budget.ts';
import {inferenceProxy} from '../packages/adapters/proxy.ts';
import {rankPaths,boundedText,reviewContext} from '../packages/workspace/src/context.ts';
function team(){
 const x=setup(),id=x.task.id,projectId=randomUUID();
 x.apply({type:'project.save',id:projectId,name:'Budget',description:'',instructions:'',classification:'standard',provider:'fixture',maxWorkers:2});
 x.apply({type:'task.revise',taskId:id,expectedVersion:x.task.version,input:input({projectId,budget:{maxTokens:150000,maxCalls:18,maxSeconds:1200,maxUsd:null}})});
 x.task.work={role:'director',phase:'planning',conversationId:null,parentId:null,title:'部長'};
 x.queue();x.claim();const rootLease=x.lease;
 x.apply({type:'run.reserve',...rootLease,tokens:30000,calls:3},runner);
 x.apply({type:'run.settle',...rootLease,tokens:7000,calls:1,costUsd:null},runner);
 x.apply({type:'team.plan',...rootLease,plan:{summary:'分担',assignments:[{title:'UI',objective:'画面',output:'UI.md',sourcePaths:['apps/desktop/src/main.tsx']},{title:'Runner',objective:'実行制御',output:'Runner.md'}]}},runner);
 x.apply({type:'run.release',...rootLease},runner);
 const root=()=>x.state.tasks.find(t=>t.id===id)!,children=()=>x.state.tasks.filter(t=>t.work?.parentId===id);
 const claim=(id:string)=>{x.apply({type:'run.claim',taskId:id,runnerId:runner.deviceId!},runner);const r=x.state.tasks.find(t=>t.id===id)!.runs.at(-1)!;return {taskId:id,runId:r.id,fencingToken:r.fencingToken};};
 return {x,root,children,claim,rootLease};
}
test('concurrent reservations preserve the director review budget and settle actual usage',()=>{
 const {x,root,children,claim}=team();const [a,b]=children(),la=claim(a.id),lb=claim(b.id);
 assert.equal(a.budget.maxTokens,52750);assert.equal(reviewReserve(root()),37500);
 x.apply({type:'run.reserve',...la,tokens:52750,calls:3},runner);
 x.apply({type:'run.reserve',...lb,tokens:52750,calls:3},runner);
 assert.equal(turnAllowance(x.state,root()).tokens,37500);
 assert.throws(()=>x.apply({type:'run.reserve',...lb,tokens:1,calls:1},runner),/token_budget|reservation_pending/);
 x.apply({type:'run.settle',...la,tokens:22000,calls:1,costUsd:null},runner);
 assert.equal(x.state.tasks.find(t=>t.id===a.id)!.runs[0].reservedTokens,0);
 assert.equal(x.state.tasks.find(t=>t.id===a.id)!.runs[0].tokens,22000);
 assert.equal(x.state.tasks.find(t=>t.id===a.id)!.runs[0].calls,1);
 x.apply({type:'run.release',...lb},runner);
 const stopped=x.state.tasks.find(t=>t.id===b.id)!.runs[0];assert.equal(stopped.tokens,52750);assert.equal(stopped.usageEstimated,true);assert.equal(stopped.reservedTokens,0);
 x.apply({type:'run.release',...lb},runner);assert.equal(x.state.tasks.find(t=>t.id===b.id)!.runs[0].tokens,52750,'release must not charge twice');
});
test('a worker cannot reserve the final review allocation',()=>{
 const {x,children,claim}=team();const [a,b]=children(),la=claim(a.id),lb=claim(b.id);
 x.apply({type:'run.reserve',...la,tokens:52750,calls:3},runner);
 x.state.tasks.find(t=>t.id===b.id)!.budget.maxTokens=60000;
 assert.throws(()=>x.apply({type:'run.reserve',...lb,tokens:60000,calls:3},runner),/team_token_budget/);
 assert.equal(x.state.tasks.find(t=>t.id===b.id)!.runs[0].calls,0);
});
test('review-only recovery preserves completed workers, historic usage and starts a fresh timed run',()=>{
 const {x,root,children}=team();root().work!.phase='reviewing';root().reason='team_token_budget';root().runs[0].tokens=70414;
 for(const [i,child] of children().entries()){child.status='succeeded';child.runs=[{...root().runs[0],id:randomUUID(),tokens:[72200,146015][i]!,endedAt:startTime.toISOString()}];}
 const saved=JSON.stringify(children());
 assert.throws(()=>x.apply({type:'team.review.resume',taskId:root().id,expectedVersion:root().version-1,additionalTokens:40000}),/version_conflict/);
 x.apply({type:'team.review.resume',taskId:root().id,expectedVersion:root().version,additionalTokens:40000});
 assert.equal(root().budget.maxTokens,328629);assert.equal(JSON.stringify(children()),saved);
 const later=new Date(startTime.getTime()+3600000);
 x.apply({type:'run.claim',taskId:root().id,runnerId:runner.deviceId!},runner,later);
 assert.equal(root().runs.length,2);assert.equal(root().runs[1].startedAt,later.toISOString());assert.equal(root().runs[0].tokens,70414);
 assert.equal(turnAllowance(x.state,root()).tokens,40000);
});
test('source selection favors assigned paths and UTF-8 excerpts are bounded and marked',()=>{
 const paths=['README.md','packages/adapters/index.ts','tests/workspace.test.ts','apps/desktop/src/main.tsx'];
 assert.equal(rankPaths(paths,{query:'画面 UI',maxBytes:1000,maxFiles:2})[0],'apps/desktop/src/main.tsx');
 assert.equal(rankPaths(paths,{query:'画面 UI',paths:['packages/adapters/index.ts'],maxBytes:1000,maxFiles:2})[0],'packages/adapters/index.ts');
 const excerpt=boundedText('日本語'.repeat(5000),1000);assert.ok(Buffer.byteLength(excerpt)<=1000);assert.ok(excerpt.includes('省略'));assert.ok(!excerpt.includes('\uFFFD'));
});
test('SSE usage handles split events and cached Claude input without counting output twice',()=>{
 const codex=new TokenMeter('codex');const data=Buffer.from('data: {"type":"response.completed","response":{"usage":{"total_tokens":12345}}}\n\n');codex.feed(data.subarray(0,15));codex.feed(data.subarray(15));assert.equal(codex.tokens,12345);
 const claude=new TokenMeter('claude');claude.observe({type:'message_start',message:{usage:{input_tokens:100,cache_creation_input_tokens:200,cache_read_input_tokens:300,output_tokens:1}}});claude.observe({type:'message_delta',usage:{output_tokens:40}});claude.observe({type:'message_delta',usage:{output_tokens:40}});assert.equal(claude.tokens,640);
});
test('inference gateway rejects oversized input and a subsequent request before it spends unreserved tokens',async()=>{
 let forwarded=0;
 const proxy=await inferenceProxy('codex','fixture',3,undefined,{tokens:15000,requestFetch:async()=>{forwarded++;return new Response('data: {"type":"response.completed","response":{"usage":{"total_tokens":10000}}}\n\n',{headers:{'content-type':'text/event-stream'}});}});
 try{
  let response=await fetch(proxy.url+'/v1/responses',{method:'POST',body:JSON.stringify({input:'x'.repeat(50000)})});assert.equal(response.status,429);assert.equal(forwarded,0);assert.equal(proxy.calls,0);
  response=await fetch(proxy.url+'/v1/responses',{method:'POST',body:'{}'});assert.equal(response.status,200);await response.text();assert.equal(proxy.tokens,10000);
  response=await fetch(proxy.url+'/v1/responses',{method:'POST',body:'{}'});assert.equal(response.status,429);assert.equal(forwarded,1);assert.equal(proxy.calls,1);
 }finally{await proxy.close();}
});

test('review context preserves complete reports when they fit, then marks bounded excerpts',()=>{
 const {children}=team(),tasks=children();for(const t of tasks){t.artifacts=[{id:randomUUID(),name:'report.md',content:'a'.repeat(20000),hash:'hash',mediaType:'text/markdown',size:20000,runId:'report',createdAt:startTime.toISOString(),cloudKey:null,cloudVerifiedAt:null}];t.runs=[{id:'report'} as any];}
 const full=reviewContext(tasks,40000);assert.ok(full.every(t=>t.artifacts[0].content.length===20000&&!t.artifacts[0].truncated));
 const small=reviewContext(tasks,10000);assert.ok(small.every(t=>t.artifacts[0].truncated));assert.ok(small.flatMap(t=>t.artifacts).reduce((n,a)=>n+Buffer.byteLength(a.content),0)<=12000);
});
