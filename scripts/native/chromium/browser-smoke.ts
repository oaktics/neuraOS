import {createServer} from 'node:http';
import {createInterface} from 'node:readline';
import {inflateSync} from 'node:zlib';
import {spawn,execFileSync} from 'node:child_process';
import {mkdir,writeFile,readFile} from 'node:fs/promises';
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
const data=process.env.NEURA_DEV_DATA_DIR??'/tmp/neura-browser109-data';
const port=Number(process.env.NEURA_DEV_PORT??44319);
if(!data.startsWith('/tmp/neura-browser'))throw Error('An isolated browser smoke data directory is required');
await mkdir(data,{recursive:true});
const submitted=new Set<string>();
const fixture=createServer((req,res)=>{
 console.log('fixture request',req.url);
 if(req.url?.startsWith('/result?')){submitted.add(new URL(req.url,'http://127.0.0.1').searchParams.get('value')??'');res.end('ok');return;}
 res.setHeader('Content-Type','text/html; charset=utf-8');
 if(req.url==='/second'){res.end(req.headers.cookie?.includes('fixtureSession=same-tab')?'<h1>Navigation verified</h1><a href="/">Return</a>':'Missing existing session');return;}
 if(req.url==='/popup'){res.end('<h1>Popup verified</h1>');return;}
 res.end(`<!doctype html><html><head><title>Browser fixture</title></head><body style="font:20px system-ui;padding:30px"><h1>neuraOS MCP fixture</h1><label>Name <input id="name" aria-label="Name"></label><button id="submit" onclick="document.querySelector('#result').textContent='Hello '+document.querySelector('#name').value;fetch('/result?value='+encodeURIComponent(document.querySelector('#name').value))">Submit</button><p id="result">Ready</p><button onclick="window.open('/popup')">Popup</button><a href="/second">Navigate</a><input type="password" value="fixture-secret" aria-label="Secret"><div style="height:1500px">Scroll fixture</div><script>document.cookie='fixtureSession=same-tab; Path=/';</script></body></html>`);
});
await new Promise<void>(r=>fixture.listen(0,'127.0.0.1',r));const address=fixture.address() as any,url=`http://127.0.0.1:${address.port}/`;
const d=await createDaemon(data);await d.app.listen({host:'127.0.0.1',port});
const project=randomUUID(),otherProject=randomUUID();
const workspaces=[project,project,otherProject].map(projectId=>({id:randomUUID(),projectId,name:'Browser smoke',path:data,branch:'',kind:'folder' as const,createdAt:''}));for(const w of workspaces)d.store.put('workspaces',w);
const tabs=workspaces.map((w,i)=>({workspaceId:w.id,projectId:w.projectId,tabId:randomUUID(),url,...(i===1?{hidden:'true'}:{})}));
const terminal={id:randomUUID(),workspaceId:workspaces[0].id,provider:'codex' as const,status:'running' as const,createdAt:'',cols:100,rows:30};d.store.put('terminals',terminal);
const config=data+'/fixture.json';await writeFile(config,JSON.stringify({dataDirectory:data,tabs}));
const executable=resolve(process.env.NEURA_APP_OUTPUT??'apps/macos/dist/neuraOS.app','Contents/MacOS/NeuraOS');
const app=spawn(executable,['--browser-fixture',config],{stdio:['ignore','pipe','pipe']});
let appLog='';app.stdout.on('data',b=>{appLog+=b;process.stdout.write(b)});app.stderr.on('data',b=>appLog+=b);
const evidence:any={startedAt:new Date().toISOString(),checks:[],tabs};
const headers={authorization:`Bearer ${d.token}`,'x-neura-browser-token':issueBrowserCredential(terminal.id)};
const mcp=spawn(process.execPath,[resolve('apps/daemon/src/supervision-mcp.mjs')],{env:{...process.env,NEURA_SUPERVISION_URL:`http://127.0.0.1:${port}`,NEURA_SUPERVISION_TOKEN_FILE:data+'/daemon-token',NEURA_SUPERVISION_WORKSPACE:terminal.workspaceId,NEURA_SUPERVISION_TERMINAL:terminal.id,NEURA_BROWSER_TOKEN:headers['x-neura-browser-token']},stdio:'pipe'});
mcp.stderr.on('data',b=>process.stderr.write(b));
let sequence=0;const pending=new Map<number,(value:any)=>void>();
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
try{
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
   const conversation=await d.app.inject({url:'/v1/agents/'+t.agentId,headers:{authorization:`Bearer ${d.token}`}});await writeFile(data+'/codex-evidence.json',conversation.body);
   // Claude uses its real session MCP config in supported print mode; the same
   // configuration factory is used by the interactive terminal launcher.
   const {claudeMCPArguments}=await import('../../../apps/daemon/src/claude-mcp.ts');
   const claudeTerminal={...terminal,id:randomUUID(),provider:'claude' as const};d.store.put('terminals',claudeTerminal);
   const program=process.env.NEURA_CLAUDE_PATH??process.env.HOME+'/.local/bin/claude';
   const args=await claudeMCPArguments(program,{endpoint:()=>`http://127.0.0.1:${port}`,tokenPath:data+'/daemon-token'},workspaces[0].id,claudeTerminal.id);
   const claude=spawn(program,['-p',prompt.replaceAll('CodexCLI','ClaudeCLI'),'--permission-mode','bypassPermissions','--output-format','stream-json','--verbose',...args],{cwd:data,env:{...process.env,CLAUDECODE:''},stdio:['ignore','pipe','pipe']});
   let output='';claude.stdout.on('data',b=>output+=b);claude.stderr.on('data',b=>output+=b);
   const timer=setTimeout(()=>claude.kill('SIGTERM'),180000);await new Promise(r=>claude.once('exit',r));clearTimeout(timer);
   await writeFile(data+'/claude-evidence.jsonl',output);assert.ok((await snap()).text.includes('Hello ClaudeCLI'));evidence.checks.push('real Claude CLI completed fixture');
 }
 await writeFile(data+'/after.png',assertPNG((await call('screenshot')).result.data));
 await call('stop');await assert.rejects(call('snapshot'),/browser_disabled/);evidence.checks.push('stop disconnects tab');
 evidence.passed=true;
}catch(error){evidence.error=String(error);throw error;}finally{
 evidence.finishedAt=new Date().toISOString();await writeFile(data+'/evidence.json',JSON.stringify(evidence,null,2));await writeFile(data+'/app.log',appLog);
 if(app.exitCode===null&&app.signalCode===null){app.kill('SIGTERM');await new Promise(r=>app.once('exit',r));}mcp.kill('SIGTERM');await d.app.close();fixture.closeAllConnections();await new Promise(r=>fixture.close(r));
 console.log(JSON.stringify(evidence,null,2));
}
