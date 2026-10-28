import {claudeMCPArguments} from '../../apps/daemon/src/claude-mcp.ts';
import {test} from 'node:test';
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {createInterface} from 'node:readline';
import {mkdtemp,mkdir,writeFile,rm} from 'node:fs/promises';
import {randomUUID} from 'node:crypto';
import {createDaemon} from '../../apps/daemon/src/server.ts';
import {git} from '../../apps/daemon/src/workspace.ts';

test('stdio MCP discovers workspaces, preserves failed startup, and deduplicates worktree creation',async()=>{
  const root=await mkdtemp('/tmp/neura-mcp-test-'),repo=root+'/repo';await mkdir(repo);
  await git(repo,['init','-b','main']);await git(repo,['config','user.name','Test']);await git(repo,['config','user.email','test@example.invalid']);await writeFile(repo+'/hello','hello');await git(repo,['add','.']);await git(repo,['commit','-m','initial']);
  const old=process.env.NEURA_CODEX_PATH;process.env.NEURA_CODEX_PATH=root+'/missing';
  const d=await createDaemon(root+'/data');await d.app.listen({host:'127.0.0.1',port:0});
  const address=d.app.server.address();assert.ok(address&&typeof address!=='string');
  const headers={authorization:`Bearer ${d.token}`};
  const p=(await d.app.inject({method:'POST',url:'/v1/commands',headers,payload:{operationId:randomUUID(),command:{type:'project.add',path:repo}}})).json();
  const workspace=d.store.state().workspaces[0];
  const probe=root+'/claude';await writeFile(probe,'#!/bin/sh\necho --mcp-config --append-system-prompt\n',{mode:0o700});
  const terminalId=randomUUID();
  const launchArgs=await claudeMCPArguments(probe,{endpoint:()=>`http://127.0.0.1:${address.port}`,tokenPath:root+'/data/daemon-token'},workspace.id,terminalId);
  const config=JSON.parse(launchArgs[1]).mcpServers.neuraos;
  const child=spawn(config.command,config.args,{env:{...process.env,...config.env},stdio:'pipe'});
  child.stderr.resume();let sequence=0;const pending=new Map<number,(value:any)=>void>();
  const lines=createInterface({input:child.stdout});lines.on('line',line=>{const m=JSON.parse(line);pending.get(m.id)?.(m);pending.delete(m.id);});
  const rpc=(method:string,params:unknown={})=>new Promise<any>((resolve,reject)=>{const id=++sequence;const timer=setTimeout(()=>reject(new Error('MCP timeout')),10000);pending.set(id,m=>{clearTimeout(timer);resolve(m.result);});child.stdin.write(JSON.stringify({jsonrpc:'2.0',id,method,params})+'\n');});
  const tool=(name:string,args:unknown={})=>rpc('tools/call',{name,arguments:args});
  try {
    assert.equal((await rpc('initialize')).serverInfo.name,'neuraos');
    const inventory=await rpc('tools/list');assert.ok(inventory.tools.some((t:any)=>t.name==='task_watch'));
    const listed=JSON.parse((await tool('workspace_list')).content[0].text);assert.equal(listed.currentWorkspaceId,workspace.id);assert.equal(listed.projects[0].id,p.id);
    const caller=JSON.parse((await tool('task_list')).content[0].text);
    assert.equal(caller.currentWorkspaceId,workspace.id);assert.equal(caller.currentTerminalId,terminalId);
    assert.deepEqual(caller.agents,[],'Claude caller need not have a registered Codex task');
    // Authenticated calls reach task validation even without a caller task ID.
    for(const name of ['task_read','task_send']){
      const result=await tool(name,{taskId:randomUUID(),operationId:randomUUID(),text:'hello'});
      assert.equal(result.isError,true);assert.match(result.content[0].text,/agent_missing/);
    }
    const args={operationId:randomUUID(),projectId:p.id,prompt:'work',baseRef:'HEAD'};
    const first=JSON.parse((await tool('task_spawn',args)).content[0].text);assert.ok(first.workspace.id);assert.match(first.startupError,/Codex/);
    const retry=JSON.parse((await tool('task_spawn',args)).content[0].text);assert.equal(retry.workspace.id,first.workspace.id);
    assert.equal(d.store.state().workspaces.length,2);assert.equal(d.store.state().terminals.length,0);
    assert.equal((await tool('unknown')).isError,true);
    const tasks=JSON.parse((await tool('task_wait',{after:0})).content[0].text);assert.ok(tasks.revision>0);assert.deepEqual(tasks.agents,[]);
    assert.equal((await d.app.inject({url:'/v1/agents'})).statusCode,401);
  }finally{child.kill();lines.close();await d.app.close();if(old===undefined)delete process.env.NEURA_CODEX_PATH;else process.env.NEURA_CODEX_PATH=old;await rm(root,{recursive:true,force:true});}
});
