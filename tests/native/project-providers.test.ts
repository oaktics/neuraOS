import {test} from 'node:test';
import assert from 'node:assert/strict';
import {mkdtemp,mkdir,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {randomUUID} from 'node:crypto';
import {createDaemon} from '../../apps/daemon/src/server.ts';
import type {Workspace,Provider} from '../../apps/daemon/src/contracts.ts';
import {Terminals} from '../../apps/daemon/src/terminals.ts';

test('project defaults persist independently, validate AI providers and select terminal provider',async t=>{
  const root=await mkdtemp(join(tmpdir(),'neura-providers-')),data=join(root,'data'),folder=join(root,'folder');
  await mkdir(folder);
  let daemon=await createDaemon(data);
  // Isolate provider selection from external CLIs and user credentials.
  const opens=t.mock.method(Terminals.prototype,'open',async(workspace:Workspace,provider:Provider,resume:boolean)=>({workspaceId:workspace.id,provider,resume}));
  const cmd=(command:unknown,operationId=randomUUID())=>daemon.app.inject({method:'POST',url:'/v1/commands',headers:{authorization:`Bearer ${daemon.token}`},payload:{operationId,command}});
  const state=async()=>(await daemon.app.inject({url:'/v1/state',headers:{authorization:`Bearer ${daemon.token}`}})).json();
  try {
    const project=(await cmd({type:'project.create',name:'First'})).json();
    const other=(await cmd({type:'project.create',name:'Second'})).json();
    const snapshot=await state();
    assert.ok(snapshot.features.includes('project.default-providers'));
    const workspaceId=snapshot.workspaces.find((w:any)=>w.projectId===project.id).id;
    const otherWorkspace=snapshot.workspaces.find((w:any)=>w.projectId===other.id).id;
    const open={type:'terminal.open',workspaceId};
    assert.equal((await cmd(open)).json().provider,'codex');
    const update={type:'project.set-default-providers',projectId:project.id};
    for(const field of ['defaultConversationProvider','defaultDelegationProvider']) {
      for(const provider of ['shell','invalid',null,42]) assert.equal((await cmd({...update,[field]:provider})).statusCode,400);
    }
    assert.equal((await cmd(update)).statusCode,400);
    assert.equal((await cmd({...update,projectId:randomUUID(),defaultConversationProvider:'claude'})).statusCode,404);
    const operationId=randomUUID();
    const configured=await cmd({...update,defaultConversationProvider:'claude',defaultDelegationProvider:'codex'},operationId);
    assert.equal(configured.statusCode,200);
    assert.deepEqual((await cmd({...update,defaultConversationProvider:'claude',defaultDelegationProvider:'codex'},operationId)).json(),configured.json());
    assert.equal((await cmd({...open,resume:true})).json().provider,'claude');
    assert.equal(opens.mock.calls.at(-1)!.arguments[2],true);
    assert.equal((await cmd({...open,provider:'codex'})).json().provider,'codex');
    assert.equal((await cmd({...open,provider:'shell'})).json().provider,'shell');
    assert.equal((await cmd({...open,provider:'unknown'})).statusCode,400);
    assert.equal((await cmd({...open,workspaceId:otherWorkspace})).json().provider,'codex');
    const partial=(await cmd({...update,defaultDelegationProvider:'claude'})).json();
    assert.equal(partial.defaultConversationProvider,'claude');
    assert.equal(partial.defaultDelegationProvider,'claude');
    await cmd({type:'project.set-worktree-startup',projectId:project.id,providers:['shell']});
    const attached=(await cmd({type:'project.attach',projectId:project.id,path:folder})).json();
    assert.equal(attached.defaultConversationProvider,'claude');
    assert.equal(attached.defaultDelegationProvider,'claude');
    assert.equal((await cmd({type:'project.add',path:folder})).json().defaultConversationProvider,'claude');
    await daemon.app.close();daemon=await createDaemon(data);
    const saved=(await state()).projects.find((p:any)=>p.id===project.id);
    assert.equal(saved.defaultDelegationProvider,'claude');
    assert.deepEqual(saved.worktreeStartup,['shell']);
    assert.equal((await cmd(open)).json().provider,'claude');
    await cmd({...update,defaultConversationProvider:'codex'});
    assert.equal((await cmd(open)).json().provider,'codex');
    assert.equal((await state()).projects.find((p:any)=>p.id===project.id).defaultDelegationProvider,'claude');
  } finally {await daemon.app.close();await rm(root,{recursive:true,force:true});}
});
