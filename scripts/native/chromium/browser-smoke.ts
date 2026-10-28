import {createServer} from 'node:http';
import {createInterface} from 'node:readline';
import {inflateSync} from 'node:zlib';
import {spawn,execFileSync,type ChildProcess} from 'node:child_process';
import {mkdir,writeFile} from 'node:fs/promises';
import {randomUUID} from 'node:crypto';
import {resolve} from 'node:path';
import assert from 'node:assert/strict';
import {createDaemon} from '../../../apps/daemon/src/server.ts';
import {issueBrowserCredential} from '../../../apps/daemon/src/browser-credentials.ts';
function assertPNG(data:string){
 const png=Buffer.from(data,'base64');assert.equal(png.subarray(1,4).toString(),'PNG');
 const width=png.readUInt32BE(16),height=png.readUInt32BE(20),channels=png[25]===6?4:3;
 assert.equal(png[24],8);assert.ok([2,6].includes(png[25]));assert.ok(width>100&&height>100);
 const chunks:Buffer[]=[];for(let p=8;p<png.length;){const length=png.readUInt32BE(p);if(png.subarray(p+4,p+8).toString()==='IDAT')chunks.push(png.subarray(p+8,p+8+length));p+=12+length;}
 const raw=inflateSync(Buffer.concat(chunks)),stride=width*channels;let prior=Buffer.alloc(stride),offset=0,dark=0;
 for(let y=0;y<height;y++){
  const filter=raw[offset++],row=Buffer.alloc(stride);
  for(let x=0;x<stride;x++){const a=x>=channels?row[x-channels]:0,b=prior[x],c=x>=channels?prior[x-channels]:0,p=a+b-c,pa=Math.abs(p-a),pb=Math.abs(p-b),pc=Math.abs(p-c);const add=[0,a,b,Math.floor((a+b)/2),pa<=pb&&pa<=pc?a:pb<=pc?b:c][filter];assert.notEqual(add,undefined);row[x]=(raw[offset++]+add)&255;}
  for(let x=0;x<stride;x+=channels)if(row[x]<100&&row[x+1]<100&&row[x+2]<100)dark++;
  prior=row;
 }
 assert.ok(dark>1000,'Screenshot must contain fixture text, not an empty/white surface');return png;
}
async function stopChild(child?:ChildProcess){
 if(!child||child.exitCode!==null||child.signalCode!==null||!child.pid)return;
 const exited=()=>new Promise<boolean>(resolve=>{const onExit=()=>{clearTimeout(timer);resolve(true)};const timer=setTimeout(()=>{child.off('exit',onExit);resolve(false)},3000);child.once('exit',onExit);});
 let wait=exited();child.kill('SIGTERM');if(await wait)return;
 wait=exited();child.kill('SIGKILL');if(!await wait)throw Error('Fixture child could not be terminated');
}
function objects(value:any):any[]{
 if(!value||typeof value!=='object')return [];return [value,...Object.values(value).flatMap(objects)];
}
function assertScreenshotTrace(value:any){
 const nodes=objects(value);
 assert.ok(nodes.some(o=>(o.type==='mcpToolCall'&&o.tool==='browser_screenshot')||(o.type==='tool_use'&&String(o.name).endsWith('browser_screenshot'))),'CLI trace must contain the actual screenshot tool call');
 assert.ok(nodes.some(o=>o.type==='image'||o.type==='image_url'||o.type==='input_image'),'CLI trace must contain an image result');
}
const data=process.env.NEURA_DEV_DATA_DIR??'/tmp/neura-browser109-data';
const port=Number(process.env.NEURA_DEV_PORT??44319);
if(!/^\/(?:private\/)?tmp\/neura-browser[^/]+$/.test(resolve(data)))throw Error('An isolated browser smoke data directory is required');
await mkdir(data,{recursive:true});
const submitted=new Set<string>();
const fixture=createServer((req,res)=>{
 console.log('fixture request',req.url);
 if(req.url?.startsWith('/result?')){submitted.add(new URL(req.url,'http://127.0.0.1').searchParams.get('value')??'');res.end('ok');return;}
 res.setHeader('Content-Type','text/html; charset=utf-8');
 if(req.url==='/second'){res.end(req.headers.cookie?.includes('fixtureSession=same-tab')?'<h1>Navigation verified</h1><a href="/">Return</a>':'Missing existing session');return;}
 if(req.url==='/popup'){res.end('<h1>Popup verified</h1><button onclick="window.close()">Close popup</button>');return;}
 res.end(`<!doctype html><html><head><title>Browser fixture</title></head><body style="font:20px system-ui;padding:30px"><h1>neuraOS MCP fixture</h1><label>Name <input id="name" aria-label="Name"></label><button id="submit" onclick="document.querySelector('#result').textContent='Hello '+document.querySelector('#name').value;fetch('/result?value='+encodeURIComponent(document.querySelector('#name').value))">Submit</button><p id="result">Ready</p><button onclick="window.open('/popup')">Popup</button><a href="/second">Navigate</a><input type="password" value="fixture-secret" aria-label="Secret"><div style="height:1500px">Scroll fixture</div><script>document.cookie='fixtureSession=same-tab; Path=/';</script></body></html>`);
});
let cleanupDaemon:Awaited<ReturnType<typeof createDaemon>>|undefined,cleanupApp:ChildProcess|undefined,cleanupMCP:ChildProcess|undefined,cleanupClaude:ChildProcess|undefined;
let appLog='';const evidence:any={startedAt:new Date().toISOString(),checks:[]};
try{
await writeFile(data+'/evidence.json',JSON.stringify(evidence,null,2));
await new Promise<void>(r=>fixture.listen(0,'127.0.0.1',r));const address=fixture.address() as any,url=`http://127.0.0.1:${address.port}/`;
const d=await createDaemon(data);cleanupDaemon=d;await d.app.listen({host:'127.0.0.1',port});
const project=randomUUID(),otherProject=randomUUID();
const workspaces=[project,project,otherProject].map(projectId=>({id:randomUUID(),projectId,name:'Browser smoke',path:data,branch:'',kind:'folder' as const,createdAt:''}));for(const w of workspaces)d.store.put('workspaces',w);
const tabs=workspaces.map((w,i)=>({workspaceId:w.id,projectId:w.projectId,tabId:randomUUID(),url,...(i===1?{hidden:'true'}:{})}));
const terminal={id:randomUUID(),workspaceId:workspaces[0].id,provider:'codex' as const,status:'running' as const,createdAt:'',cols:100,rows:30};d.store.put('terminals',terminal);
const config=data+'/fixture.json';await writeFile(config,JSON.stringify({dataDirectory:data,tabs}));
const executable=resolve(process.env.NEURA_APP_OUTPUT??'apps/macos/dist/neuraOS.app','Contents/MacOS/NeuraOS');
const app=spawn(executable,['--browser-fixture',config],{stdio:['ignore','pipe','pipe']});cleanupApp=app;app.on('error',error=>{appLog+=String(error)});
app.stdout.on('data',b=>{appLog+=b;process.stdout.write(b)});app.stderr.on('data',b=>appLog+=b);
evidence.tabs=tabs;
const headers={authorization:`Bearer ${d.token}`,'x-neura-browser-token':issueBrowserCredential(terminal.id)};
const mcp=spawn(process.execPath,[resolve('apps/daemon/src/supervision-mcp.mjs')],{env:{...process.env,NEURA_SUPERVISION_URL:`http://127.0.0.1:${port}`,NEURA_SUPERVISION_TOKEN_FILE:data+'/daemon-token',NEURA_SUPERVISION_WORKSPACE:terminal.workspaceId,NEURA_SUPERVISION_TERMINAL:terminal.id,NEURA_BROWSER_TOKEN:headers['x-neura-browser-token']},stdio:'pipe'});
cleanupMCP=mcp;mcp.on('error',error=>{appLog+=String(error)});mcp.stderr.on('data',b=>process.stderr.write(b));mcp.stdin.on('error',()=>{});
let sequence=0;const pending=new Map<number,(value:any)=>void>();
mcp.once('exit',()=>{for(const resolve of pending.values())resolve({result:{isError:true,content:[{type:'text',text:'MCP exited'}]}});pending.clear()});
createInterface({input:mcp.stdout}).on('line',line=>{const message=JSON.parse(line);pending.get(message.id)?.(message);pending.delete(message.id);});
const rpc=(method:string,params:any={})=>new Promise<any>((resolve,reject)=>{const id=++sequence;const timer=setTimeout(()=>reject(Error('MCP response timeout')),30000);pending.set(id,message=>{clearTimeout(timer);resolve(message.result)});mcp.stdin.write(JSON.stringify({jsonrpc:'2.0',id,method,params})+'\n');});
await rpc('initialize');assert.ok((await rpc('tools/list')).tools.some((t:any)=>t.name==='browser_screenshot'));
const call=async(action:string,args:any={},i=0)=>{
 const response=await rpc('tools/call',{name:'browser_'+action,arguments:{...(action==='list'?{}:{workspaceId:tabs[i].workspaceId,tabId:tabs[i].tabId}),...args}});
 if(response.isError)throw Error(response.content[0].text);
 const value=JSON.parse(response.content[0].text);
 if(action==='screenshot'){assert.equal(response.content[1].type,'image');assert.equal(response.content[1].mimeType,'image/png');return {...value,result:{data:response.content[1].data}};}
 return value;
};
const snap=async(i=0)=>(await call('snapshot',{},i)).result;
const ref=(s:any,name:string)=>{const element=s.elements.find((e:any)=>e.name===name);assert.ok(element,`Missing ${name}: ${JSON.stringify(s)}`);return element.ref;};
 for(let i=0;i<300;i++){try{const listed=(await call('list')).tabs;if(listed.length===2&&listed.every((t:any)=>t.title==='Browser fixture'&&!t.loading))break;}catch{}await new Promise(r=>setTimeout(r,200));}
 assert.ok((await call('list')).tabs.every((t:any)=>t.title==='Browser fixture'),'CEF fixture must finish initial navigation before DevTools attach');
 assert.equal((await call('list')).tabs.length,2);evidence.checks.push('same-project list; foreign project excluded');
 await call('wait',{text:'neuraOS MCP fixture',timeoutMs:10000});
 let s=await snap();assert.ok(!JSON.stringify(s).includes('fixture-secret'));evidence.checks.push('CEF DOM snapshot; password excluded');
 const screenshot=(await call('screenshot')).result.data;assert.ok(screenshot.length>100);await writeFile(data+'/before.png',assertPNG(screenshot));evidence.checks.push('CEF PNG screenshot');
 const stale=ref(s,'Submit');await call('fill',{ref:ref(s,'Name'),text:'CEF Bridge'});
 await assert.rejects(call('click',{ref:stale}),/browser_stale_ref/);evidence.checks.push('stale refs rejected after input');
 s=await snap();await call('click',{ref:ref(s,'Submit')});await call('wait',{text:'Hello CEF Bridge'});
 assert.ok((await snap()).text.includes('Hello CEF Bridge'));evidence.checks.push('fill -> click -> visible result reread');
 assert.ok(!(await snap(1)).text.includes('Hello CEF Bridge'));await writeFile(data+'/hidden.png',assertPNG((await call('screenshot',{},1)).result.data));evidence.checks.push('hidden other-workspace same-URL tab snapshot and PNG isolated');
 s=await snap();const scrolled=await call('scroll',{ref:s.elements.find((e:any)=>e.tag==='body').ref,x:0,y:300});assert.ok(scrolled.result.scrollY>0);evidence.checks.push('document scrollY changed');
 s=await snap();await call('scroll',{ref:s.elements.find((e:any)=>e.tag==='body').ref,x:0,y:-300});
 s=await snap();await call('fill',{ref:ref(s,'Name'),text:'Key'});s=await snap();await call('key',{ref:ref(s,'Submit'),key:'Enter'});await call('wait',{text:'Hello Key'});evidence.checks.push('real key Enter activates button');
 s=await snap();await call('click',{ref:ref(s,'Popup')});
 for(let i=0;i<50&&(await call('list')).tabs.length<3;i++)await new Promise(r=>setTimeout(r,100));
 assert.equal((await call('list')).tabs.length,3);evidence.checks.push('popup registered in same project');
 const popup=(await call('list')).tabs.find((t:any)=>!tabs.some(known=>known.tabId===t.tabId));
 const popupSnapshot=(await call('snapshot',{workspaceId:popup.workspaceId,tabId:popup.tabId})).result;
 try{await call('click',{workspaceId:popup.workspaceId,tabId:popup.tabId,ref:ref(popupSnapshot,'Close popup')});}catch(error){assert.match(String(error),/browser_tab_closed/);}
 for(let i=0;i<50&&(await call('list')).tabs.length!==2;i++)await new Promise(r=>setTimeout(r,100));
 await assert.rejects(call('snapshot',{workspaceId:popup.workspaceId,tabId:popup.tabId}),/browser_tab_closed/);evidence.checks.push('closed popup removed from native registry');
 await call('navigate',{url:url+'second'});await call('wait',{text:'Navigation verified'});await assert.rejects(call('click',{ref:stale}),/browser_stale_ref/);evidence.checks.push('navigation retains CEF session cookie; stale document refs rejected');
 await call('navigate',{url});await call('wait',{text:'neuraOS MCP fixture'});
 if(process.env.NEURA_BROWSER_REAL_CLI==='1'){
   // Actual managed Codex startup path injects the scoped credential and runs in
   // the terminal registered by neuraOS, against the already-mounted CEF tab.
   const prompt=`Use only neuraos browser MCP tools for this fixture test. Do not use shell or other browser tools. First list tabs, then snapshot and screenshot workspace ${tabs[0].workspaceId} tab ${tabs[0].tabId}. Fill Name with CodexCLI, get fresh snapshot, click Submit, wait for Hello CodexCLI, and reread snapshot. Report success only when observed.`;
   const opened=await d.app.inject({method:'POST',url:'/v1/commands',headers:{authorization:`Bearer ${d.token}`},payload:{operationId:randomUUID(),command:{type:'terminal.open',workspaceId:workspaces[0].id,provider:'codex',prompt}}});
   assert.equal(opened.statusCode,200,opened.body);const t=opened.json();
   for(let i=0;i<180&&!submitted.has('CodexCLI');i++)await new Promise(r=>setTimeout(r,1000));
   for(let i=0;i<60;i++){const agent=d.store.get<any>('agents',t.agentId);if(agent?.lastTurnStatus==='completed')break;await new Promise(r=>setTimeout(r,1000));}
   assert.ok((await snap()).text.includes('Hello CodexCLI'));evidence.checks.push('managed real Codex CLI completed fixture');
   const conversation=await d.app.inject({url:'/v1/agents/'+t.agentId,headers:{authorization:`Bearer ${d.token}`}});await writeFile(data+'/codex-evidence.json',conversation.body);assertScreenshotTrace(conversation.json());evidence.checks.push('Codex screenshot tool call and image result recorded');
   // Claude uses its real session MCP config in supported print mode; the same
   // configuration factory is used by the interactive terminal launcher.
   const {claudeMCPArguments}=await import('../../../apps/daemon/src/claude-mcp.ts');
   const claudeTerminal={...terminal,id:randomUUID(),provider:'claude' as const};d.store.put('terminals',claudeTerminal);
   const program=process.env.NEURA_CLAUDE_PATH??process.env.HOME+'/.local/bin/claude';
   const args=await claudeMCPArguments(program,{endpoint:()=>`http://127.0.0.1:${port}`,tokenPath:data+'/daemon-token'},workspaces[0].id,claudeTerminal.id);
   const claude=spawn(program,['-p',prompt.replaceAll('CodexCLI','ClaudeCLI'),'--permission-mode','bypassPermissions','--output-format','stream-json','--verbose',...args],{cwd:data,env:{...process.env,CLAUDECODE:''},stdio:['ignore','pipe','pipe']});
   cleanupClaude=claude;claude.on('error',error=>{appLog+=String(error)});
   let output='';claude.stdout.on('data',b=>output+=b);claude.stderr.on('data',b=>output+=b);
   const timer=setTimeout(()=>{void stopChild(claude)},180000);await new Promise(r=>claude.once('exit',r));clearTimeout(timer);
   await writeFile(data+'/claude-evidence.jsonl',output);assertScreenshotTrace(output.split('\n').flatMap(line=>{try{return [JSON.parse(line)]}catch{return []}}));evidence.checks.push('Claude screenshot tool call and image result recorded');assert.ok((await snap()).text.includes('Hello ClaudeCLI'));evidence.checks.push('real Claude CLI completed fixture');
 }
 await writeFile(data+'/after.png',assertPNG((await call('screenshot')).result.data));
 await call('stop');await assert.rejects(call('snapshot'),/browser_disabled/);evidence.checks.push('stop disconnects tab');
 // Crash only renderer children of this isolated fixture app, never user apps.
 const waiting=call('wait',{text:'never appears',timeoutMs:15000},1);
 const crashed=assert.rejects(waiting,/browser_renderer_crashed/);
 await new Promise(r=>setTimeout(r,300));
 const renderers=execFileSync('ps',['-axo','pid=,ppid=,command='],{encoding:'utf8'}).split('\n').flatMap(line=>{
  const m=line.match(/^\s*(\d+)\s+(\d+)\s+(.+)$/);return m&&Number(m[2])===app.pid&&m[3].includes('--type=renderer')?[Number(m[1])]:[];
 });assert.ok(renderers.length>0);for(const pid of renderers)process.kill(pid,'SIGKILL');await crashed;evidence.checks.push('renderer crash explicitly cancels pending operation');
 await stopChild(app);await new Promise(r=>setTimeout(r,3300));await assert.rejects(call('list'),/browser_disconnected/);evidence.checks.push('app disconnect reported');
 const restarted=spawn(executable,['--browser-fixture',config],{stdio:['ignore','pipe','pipe']});cleanupApp=restarted;
 restarted.on('error',error=>{appLog+=String(error)});restarted.stdout.on('data',b=>appLog+=b);restarted.stderr.on('data',b=>appLog+=b);
 for(let i=0;i<300;i++){try{if((await call('list')).tabs.length===2)break;}catch{}await new Promise(r=>setTimeout(r,200));}
 assert.equal((await call('list')).tabs.length,2);await assert.rejects(call('snapshot'),/browser_disabled/);evidence.checks.push('app restart reconnects registry and preserves user disconnect');
 evidence.passed=true;
}catch(error){evidence.error=String(error);throw error;}finally{
 const watchdog=setTimeout(()=>{console.error('Fixture cleanup exceeded 20 seconds');process.exit(1)},20000);
 try{
  // Clean up even if initialize, package launch or evidence writing failed.
  const stopped=await Promise.allSettled([stopChild(cleanupApp),stopChild(cleanupMCP),stopChild(cleanupClaude)]);
  const errors=stopped.flatMap(r=>r.status==='rejected'?[String(r.reason)]:[]);
  if(errors.length){evidence.cleanupErrors=errors;evidence.passed=false;process.exitCode=1;}
  if(cleanupDaemon)await cleanupDaemon.app.close();
  fixture.closeAllConnections();if(fixture.listening)await new Promise<void>(r=>fixture.close(()=>r()));
  evidence.finishedAt=new Date().toISOString();await writeFile(data+'/evidence.json',JSON.stringify(evidence,null,2));await writeFile(data+'/app.log',appLog);
  console.log(JSON.stringify(evidence,null,2));
 }finally{clearTimeout(watchdog)}
}
