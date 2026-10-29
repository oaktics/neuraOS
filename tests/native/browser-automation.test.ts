import {test} from 'node:test';
import assert from 'node:assert/strict';
import {mkdtemp,rm} from 'node:fs/promises';
import {randomUUID} from 'node:crypto';
import {createDaemon} from '../../apps/daemon/src/server.ts';
import {issueBrowserCredential} from '../../apps/daemon/src/browser-credentials.ts';
import {browserTools,callBrowser} from '../../apps/daemon/src/browser-tools.mjs';

async function fixture(){
 const root=await mkdtemp('/tmp/neura-browser-test-'),d=await createDaemon(root);
 const projectId=randomUUID(),otherProjectId=randomUUID();
 const workspaces=[projectId,projectId,otherProjectId].map(projectId=>({id:randomUUID(),projectId,name:'fixture',path:root,branch:'main',kind:'worktree' as const,createdAt:''}));
 for(const w of workspaces)await d.store.put('workspaces',w);
 const terminals=workspaces.map(w=>({id:randomUUID(),workspaceId:w.id,provider:'codex' as const,status:'running' as const,createdAt:'',cols:80,rows:24}));for(const t of terminals)await d.store.put('terminals',t);
 const tabs=workspaces.map(w=>({workspaceId:w.id,projectId:w.projectId,tabId:randomUUID(),url:'http://127.0.0.1/same',title:'Fixture',selected:true,loading:false,enabled:true}));
 const headers={authorization:`Bearer ${d.token}`};let nativeId=randomUUID();
 const poll=(results:any[]=[],listed=tabs)=>d.app.inject({method:'POST',url:'/v1/browser/native/poll',headers,payload:{nativeId,tabs:listed,results}});
 const call=(command:any,index=0,extra={})=>d.app.inject({method:'POST',url:'/v1/browser/call',headers:{...headers,'x-neura-browser-token':issueBrowserCredential(terminals[index].id),...extra},payload:{terminalId:terminals[index].id,command}});
 const target=(i=0)=>({workspaceId:tabs[i].workspaceId,tabId:tabs[i].tabId});
 const next=async()=>{for(let i=0;i<100;i++){const p=(await poll()).json();if(p.requests.length)return p.requests;await new Promise(r=>setTimeout(r,5));}throw Error('No native request');};
 await poll();
 return {d,tabs,terminals,poll,call,target,next,headers,restart:()=>{nativeId=randomUUID()},async close(){await d.app.close();await rm(root,{recursive:true,force:true});}};
}
test('browser caller credential binds terminal; native and server enforce project ownership',async()=>{
 const f=await fixture();try{
  assert.equal((await f.call({action:'list'})).json().tabs.length,2);
  assert.equal((await f.call({action:'list',workspaceId:f.tabs[2].workspaceId})).statusCode,403);
  assert.equal((await f.call({action:'snapshot',...f.target(2)})).statusCode,403);
  const spoof=await f.call({action:'list'},2,{'x-neura-browser-token':issueBrowserCredential(f.terminals[0].id)});
  assert.equal(spoof.statusCode,403);assert.equal(spoof.json().error,'browser_caller_unauthorized');
  assert.equal((await f.call({action:'list'},0,{'x-neura-browser-token':''})).statusCode,403);
  assert.equal((await f.d.app.inject({method:'POST',url:'/v1/browser/call',payload:{terminalId:f.terminals[0].id,command:{action:'list'}}})).statusCode,401);
  assert.equal((await f.call({action:'evaluate',...f.target(),script:'document.cookie'})).statusCode,400);
  // Native cannot relabel another project's workspace to expose it.
  await f.poll([],f.tabs.map(t=>({...t,projectId:f.tabs[0].projectId})));
  assert.equal((await f.call({action:'list'},2)).json().tabs.length,0);
  await f.d.store.put('terminals',{...f.terminals[0],status:'exited'});
  assert.equal((await f.call({action:'list'})).statusCode,403);
 }finally{await f.close();}
});
test('same URL tabs route by IDs; busy, result release, disabled and closed handling',async()=>{
 const f=await fixture();try{
  const first=f.call({action:'fill',...f.target(1),ref:'r',text:'fixture'}).then(r=>r);
  const [request]=await f.next();assert.equal(request.command.tabId,f.tabs[1].tabId);
  assert.equal((await f.call({action:'snapshot',...f.target(1)})).json().error,'browser_busy');
  await f.poll([{id:request.id,result:{filled:true}}]);assert.equal((await first).statusCode,200);
  const second=f.call({action:'snapshot',...f.target(1)}).then(r=>r);const [r2]=await f.next();
  assert.notEqual(r2.id,request.id);await f.poll([{id:r2.id,error:'browser_stale_ref'}]);assert.equal((await second).json().error,'browser_stale_ref');
  f.tabs[1].enabled=false;await f.poll();assert.equal((await f.call({action:'snapshot',...f.target(1)})).json().error,'browser_disabled');
  await f.poll([],[]);assert.equal((await f.call({action:'snapshot',...f.target()})).json().error,'browser_tab_closed');
 }finally{await f.close();}
});
test('timeout is not retry: tab stays quarantined until native cancellation acknowledgement',async()=>{
 const f=await fixture();try{
  const first=f.call({action:'wait',...f.target(),text:'missing',timeoutMs:100}).then(r=>r);
  const [request]=await f.next();
  let response:any;first.then(r=>response=r);
  for(let i=0;i<60&&!response;i++){await f.poll();await new Promise(r=>setTimeout(r,50));}
  assert.equal((await first).json().error,'browser_timeout');
  const poll=(await f.poll()).json();assert.deepEqual(poll.requests,[]);assert.ok(poll.cancelIds.includes(request.id));
  assert.equal((await f.call({action:'click',...f.target(),ref:'r'})).json().error,'browser_busy');
  await f.poll([{id:request.id,error:'browser_cancelled'}]);
  const next=f.call({action:'snapshot',...f.target()}).then(r=>r);const [r2]=await f.next();await f.poll([{id:r2.id,result:{}}]);assert.equal((await next).statusCode,200);
 }finally{await f.close();}
});
test('stop cancels in-flight calls and does not release their locks early',async()=>{
 const f=await fixture();try{
  const pending=f.call({action:'click',...f.target(),ref:'r'}).then(r=>r);const [request]=await f.next();
  const stop=f.call({action:'stop',...f.target()}).then(r=>r);const [stopRequest]=await f.next();
  assert.equal((await pending).json().error,'browser_cancelled');
  await f.poll([{id:stopRequest.id,result:{stopped:true}}]);assert.equal((await stop).statusCode,200);
  assert.equal((await f.call({action:'snapshot',...f.target()})).json().error,'browser_busy');
  f.tabs[0].enabled=false;await f.poll([{id:request.id,error:'browser_cancelled'}]);assert.equal((await f.call({action:'snapshot',...f.target()})).json().error,'browser_disabled');
 }finally{await f.close();}
});
test('browser MCP returns images and cannot override action or caller',async()=>{
 assert.ok(browserTools.find(t=>t.name==='browser_screenshot'));
 let payload:any,headers:any;
 const request=async(_path:any,body:any,h:any)=>{payload=body;headers=h;return {workspaceId:'w',tabId:'t',result:{data:'cG5n'}};};
 const result=await callBrowser('browser_screenshot',{workspaceId:'w',tabId:'t'},request,'caller','credential');
 assert.equal(result.content[1].type,'image');assert.equal(result.content[1].mimeType,'image/png');assert.equal(payload.terminalId,'caller');assert.equal(headers['x-neura-browser-token'],'credential');
 await assert.rejects(callBrowser('browser_snapshot',{action:'navigate'},request,'caller','credential'));
});
test('disconnect quarantines dispatched work until reconnect acknowledges cancellation; new app replaces stale registry',async()=>{
 const f=await fixture();try{
  const result=f.call({action:'click',...f.target(),ref:'r'}).then(r=>r);const [r]=await f.next();
  assert.equal((await result).json().error,'browser_disconnected');
  assert.equal((await f.call({action:'list'})).json().error,'browser_disconnected');
  const reconnect=(await f.poll()).json();assert.ok(reconnect.cancelIds.includes(r.id));assert.equal(reconnect.requests.length,0);
  assert.equal((await f.call({action:'snapshot',...f.target()})).json().error,'browser_busy');
  await f.poll([{id:r.id,error:'browser_cancelled'}]);
  await new Promise(r=>setTimeout(r,3100));f.restart();assert.equal((await f.poll()).statusCode,200);
  const next=f.call({action:'snapshot',...f.target()}).then(r=>r);const [request]=await f.next();await f.poll([{id:request.id,result:{}}]);assert.equal((await next).statusCode,200);
 }finally{await f.close();}
});
test('oversized screenshot error acknowledges and releases the tab for subsequent reads',async()=>{
 const f=await fixture();try{
  const image=f.call({action:'screenshot',...f.target()}).then(r=>r);const [request]=await f.next();
  await f.poll([{id:request.id,error:'browser_image_too_large'}]);assert.equal((await image).json().error,'browser_image_too_large');
  const read=f.call({action:'snapshot',...f.target()}).then(r=>r);const [next]=await f.next();
  await f.poll([{id:next.id,result:{text:'recovered'}}]);assert.equal((await read).json().result.text,'recovered');
 }finally{await f.close();}
});
test('ordinary 30-second budget expires without releasing dispatched native work (fake clock)',async t=>{
 t.mock.timers.enable({apis:['Date','setTimeout'],now:Date.now()});
 const f=await fixture();try{
  const result=f.call({action:'snapshot',...f.target()}).then(r=>r);const [request]=await f.next();
  assert.equal(request.deadline-Date.now(),30000);
  for(let i=0;i<14;i++){t.mock.timers.tick(2000);await f.poll();}
  t.mock.timers.tick(2501);
  assert.equal((await result).json().error,'browser_timeout');
  const poll=(await f.poll()).json();assert.deepEqual(poll.requests,[]);assert.ok(poll.cancelIds.includes(request.id));
  assert.equal((await f.call({action:'click',...f.target(),ref:'r'})).json().error,'browser_busy');
  await f.poll([{id:request.id,error:'browser_cancelled'}]);
  const next=f.call({action:'snapshot',...f.target()}).then(r=>r);const [r2]=await f.next();await f.poll([{id:r2.id,result:{}}]);assert.equal((await next).statusCode,200);
 }finally{await f.close();t.mock.timers.reset();}
});
