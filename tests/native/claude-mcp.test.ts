import {test} from 'node:test';
import assert from 'node:assert/strict';
import {mkdtemp,writeFile,readFile,rm} from 'node:fs/promises';
import {randomUUID} from 'node:crypto';
import {createDaemon} from '../../apps/daemon/src/server.ts';
import {claudeMCPArguments} from '../../apps/daemon/src/claude-mcp.ts';
import {claudeSessionInstructions,sharedSessionInstructions} from '../../apps/daemon/src/session-instructions.ts';

for(const resume of [false,true])test(`daemon injects session-only Claude MCP and shared instructions on ${resume?'resume':'start'}, alongside hooks`,async()=>{
  const root=await mkdtemp('/tmp/neura-claude-mcp-'),program=root+'/claude',capture=root+'/args.json';
  await writeFile(program,`#!/usr/bin/env node
import {writeFileSync} from 'node:fs';
if(process.argv.includes('--help')){console.log('--mcp-config --append-system-prompt --settings');process.exit(0);}
if(process.argv.includes('--version')){console.log('2.1.312');process.exit(0);}
writeFileSync(${JSON.stringify(capture)},JSON.stringify(process.argv.slice(2)));
setInterval(()=>{},1000);
`,{mode:0o700});
  const old=process.env.NEURA_CLAUDE_PATH;process.env.NEURA_CLAUDE_PATH=program;
  const d=await createDaemon(root+'/data');
  try{
    await d.app.listen({host:'127.0.0.1',port:0});
    const address=d.app.server.address();assert.ok(address&&typeof address!=='string');
    const workspace={id:randomUUID(),projectId:randomUUID(),name:'test',path:root,branch:'main',kind:'worktree' as const,createdAt:''};d.store.put('workspaces',workspace);
    const response=await d.app.inject({method:'POST',url:'/v1/commands',headers:{authorization:`Bearer ${d.token}`},payload:{operationId:randomUUID(),command:{type:'terminal.open',workspaceId:workspace.id,provider:'claude',resume}}});
    assert.equal(response.statusCode,200,response.body);const terminal=response.json();
    let args:string[]=[];
    for(let i=0;i<100;i++){try{args=JSON.parse(await readFile(capture,'utf8'));break;}catch{await new Promise(r=>setTimeout(r,25));}}
    assert.ok(args.length,'CLI started');
    assert.equal(args.includes('--resume'),resume);
    assert.equal(args[args.indexOf('--permission-mode')+1],'bypassPermissions');
    const config=JSON.parse(args[args.indexOf('--mcp-config')+1]).mcpServers.neuraos;
    assert.equal(config.env.NEURA_SUPERVISION_URL,`http://127.0.0.1:${address.port}`);
    assert.equal(config.env.NEURA_SUPERVISION_WORKSPACE,workspace.id);
    assert.equal(config.env.NEURA_SUPERVISION_TERMINAL,terminal.id);
    assert.equal(config.env.NEURA_SUPERVISION_TOKEN_FILE,root+'/data/daemon-token');
    assert.equal(config.type,'stdio');assert.equal(config.command,process.execPath);
    assert.match(config.args[0],/supervision-mcp\.mjs$/);
    assert.equal(args[args.indexOf('--append-system-prompt')+1],claudeSessionInstructions);
    assert.ok(claudeSessionInstructions.startsWith(sharedSessionInstructions));
    assert.match(claudeSessionInstructions,/registered neuraOS task/);
    assert.ok(args.includes('--dangerously-load-development-channels'));
    assert.ok(JSON.parse(args[args.indexOf('--settings')+1]).hooks.SessionStart);
    assert.equal(JSON.stringify(args).includes(d.token),false,'bearer secret is not in argv');
    assert.equal(args.includes('--strict-mcp-config'),false,'retain other configured MCP servers');
    assert.equal(terminal.agentId,undefined,'Claude is not falsely registered as Codex');
    assert.deepEqual(d.store.list('agents'),[]);
  }finally{await d.app.close();if(old===undefined)delete process.env.NEURA_CLAUDE_PATH;else process.env.NEURA_CLAUDE_PATH=old;await rm(root,{recursive:true,force:true});}
});

test('unsupported Claude CLI fails with an actionable error before starting a terminal',async()=>{
  const root=await mkdtemp('/tmp/neura-old-claude-'),program=root+'/claude';
  try{
    await writeFile(program,'#!/bin/sh\necho --settings\n',{mode:0o700});
    await assert.rejects(claudeMCPArguments(program,{endpoint:()=> 'http://127.0.0.1:1234',tokenPath:'/tmp/token'},randomUUID(),randomUUID()),{code:'claude_mcp_unsupported'});
  }finally{await rm(root,{recursive:true,force:true});}
});

test('Claude registration retains terminal identity; channel credentials reject other terminals before consuming queue',async()=>{
  const root=await mkdtemp('/tmp/neura-channel-auth-'),program=root+'/claude',sessionId=randomUUID();
  await writeFile(program,`#!/usr/bin/env node
import {createConnection} from 'node:net';
if(process.argv.includes('--help')){console.log('--mcp-config --append-system-prompt --settings');process.exit(0);}
if(process.argv.includes('--version')){console.log('2.1.312');process.exit(0);}
process.on('SIGINT',()=>{});
const socket=createConnection(process.env.NEURA_ACTIVITY_SOCKET);
socket.on('error',()=>{});socket.on('connect',()=>socket.end(JSON.stringify({hook_event_name:'SessionStart',source:'startup',session_id:${JSON.stringify(sessionId)}})+'\\n'));
process.stdin.on('data',data=>{const s=createConnection(process.env.NEURA_ACTIVITY_SOCKET);s.on('error',()=>{});s.on('connect',()=>s.end(JSON.stringify({hook_event_name:data.toString().includes('wait')?'PermissionRequest':'Stop',session_id:${JSON.stringify(sessionId)}})+'\\n'));});
setInterval(()=>{},1000);
`,{mode:0o700});
  const old=process.env.NEURA_CLAUDE_PATH;process.env.NEURA_CLAUDE_PATH=program;
  const d=await createDaemon(root+'/data');const headers={authorization:`Bearer ${d.token}`};
  const {channelCredential}=await import('../../apps/daemon/src/channel-credentials.ts');
  try{
    const workspace={id:randomUUID(),projectId:randomUUID(),name:'test',path:root,branch:'main',kind:'worktree' as const,createdAt:''};d.store.put('workspaces',workspace);
    const response=await d.app.inject({method:'POST',url:'/v1/commands',headers,payload:{operationId:randomUUID(),command:{type:'terminal.open',workspaceId:workspace.id,provider:'claude',prompt:'first instruction'}}});
    assert.equal(response.statusCode,200,response.body);const terminal=response.json();
    for(let i=0;i<150&&!d.store.state().terminals[0].agentId;i++)await new Promise(r=>setTimeout(r,20));
    assert.equal(d.store.state().terminals[0].agentId,sessionId,'activity store must preserve registration agentId');
    const poll=(credential?:string)=>d.app.inject({method:'POST',url:`/v1/claude/${terminal.id}/channel`,headers:{...headers,...(credential?{'x-neura-channel-token':credential}:{})},payload:{}});
    assert.equal((await poll()).statusCode,403);
    assert.equal((await poll(await channelCredential(root+'/data/daemon-token',randomUUID()))).statusCode,403);
    const self=await channelCredential(root+'/data/daemon-token',terminal.id);
    const probe=await poll(self);assert.equal(probe.statusCode,200);assert.equal(probe.json().meta.kind,'probe');
    assert.deepEqual((await poll(self)).json(),{},'initialized MCP without channel receipt cannot consume instructions');
    const before=d.store.list<any>('agents').find(a=>a.id===sessionId);assert.equal(before.status,'idle');assert.equal(before.pending[0].text,'first instruction');
    const nonce=probe.json().content.match(/nonce ([a-f0-9-]{36})/)[1];
    const receipt=await d.app.inject({method:'POST',url:`/v1/claude/${terminal.id}/channel-ack`,headers:{...headers,'x-neura-channel-token':self},payload:{nonce}});assert.equal(receipt.statusCode,200);
    await d.app.inject({method:'POST',url:'/v1/commands',headers,payload:{operationId:randomUUID(),command:{type:'terminal.input',terminalId:terminal.id,clientId:'12777777-2222-4333-8444-555555555551',data:'stop\r'}}});
    await new Promise(r=>setTimeout(r,100));
    const delivery=await poll(self);assert.equal(delivery.statusCode,200);assert.equal(delivery.json().content,'first instruction');
    assert.deepEqual((await poll(self)).json(),{});
    for(const key of ['\x1b','\x03']){
      await d.app.inject({method:'POST',url:'/v1/commands',headers,payload:{operationId:randomUUID(),command:{type:'terminal.input',terminalId:terminal.id,clientId:'12777777-2222-4333-8444-555555555551',data:key}}});
      assert.equal(d.store.get<any>('agents',sessionId).status,'interrupted');assert.equal(d.store.get<any>('agents',sessionId).turnId,undefined);
      await d.app.inject({method:'POST',url:'/v1/commands',headers,payload:{operationId:randomUUID(),command:{type:'agent.send',agentId:sessionId,text:'recover native interrupt'}}});
      assert.equal((await poll(self)).json().content,'recover native interrupt');
    }
    const input=(data:string)=>d.app.inject({method:'POST',url:'/v1/commands',headers,payload:{operationId:randomUUID(),command:{type:'terminal.input',terminalId:terminal.id,clientId:'12777777-2222-4333-8444-555555555551',data}}});
    await input('wait\r');await new Promise(r=>setTimeout(r,100));assert.equal(d.store.get<any>('agents',sessionId).status,'waiting');
    await input('\x03');assert.equal(d.store.get<any>('agents',sessionId).status,'waiting','a waiting dialog is not cancelled merely by Ctrl-C');
    await d.app.inject({method:'POST',url:'/v1/commands',headers,payload:{operationId:randomUUID(),command:{type:'agent.send',agentId:sessionId,text:'after actual dialog cancellation'}}});
    assert.deepEqual((await poll(self)).json(),{});assert.equal(d.store.get<any>('agents',sessionId).pending.length,1);
    await input('stop\r');await new Promise(r=>setTimeout(r,100));assert.equal((await poll(self)).json().content,'after actual dialog cancellation');
    const recipient=randomUUID();d.store.put('agents',{id:recipient,terminalId:randomUUID(),workspaceId:workspace.id,name:'recipient',status:'interrupted',pending:[],requests:[],updatedAt:''});
    const report=await d.app.inject({method:'POST',url:'/v1/commands',headers,payload:{operationId:randomUUID(),command:{type:'agent.report',agentId:recipient,text:'proof',sourceTerminalId:terminal.id}}});
    assert.equal(report.statusCode,200);assert.equal((d.store.list('agents').find((a:any)=>a.id===recipient) as any).reports[0].sourceTaskId,sessionId);
  }finally{await d.app.close();if(old===undefined)delete process.env.NEURA_CLAUDE_PATH;else process.env.NEURA_CLAUDE_PATH=old;await rm(root,{recursive:true,force:true});}
});
