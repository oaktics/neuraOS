import {test} from 'node:test';
import assert from 'node:assert/strict';
import {mkdtemp,mkdir,writeFile,readFile,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {randomUUID} from 'node:crypto';
import {createDaemon} from '../../apps/daemon/src/server.ts';
import {git} from '../../apps/daemon/src/workspace.ts';

for(const kind of ['folder','git','scratch'] as const)test(`project removal preserves ${kind} files and unrelated registrations`,async()=>{
  const root=await mkdtemp(join(tmpdir(),'neura-remove-')),folder=join(root,'project'),data=join(root,'data');
  await mkdir(folder);
  if(kind==='git'){
    await git(folder,['init','-b','main']);
    await git(folder,['-c','user.name=Test','-c','user.email=test@example.invalid','commit','--allow-empty','-m','initial']);
  }
  let daemon=await createDaemon(data);
  const cmd=(command:unknown,operationId=randomUUID())=>daemon.app.inject({method:'POST',url:'/v1/commands',headers:{authorization:`Bearer ${daemon.token}`},payload:{operationId,command}});
  const state=async()=>(await daemon.app.inject({url:'/v1/state',headers:{authorization:`Bearer ${daemon.token}`}})).json();
  try{
    const project=(await cmd(kind==='scratch'?{type:'project.create',name:'scratch'}:{type:'project.add',path:folder})).json();
    const other=(await cmd({type:'project.create',name:'keep'})).json();
    if(kind==='git')assert.equal((await cmd({type:'workspace.create',projectId:project.id,baseRef:'HEAD'})).statusCode,200);
    const before=await state(),workspaces=before.workspaces.filter((w:any)=>w.projectId===project.id);
    for(const workspace of workspaces){
      await writeFile(join(workspace.path,'.env'),'preserve secret');
      const terminal=await cmd({type:'terminal.open',workspaceId:workspace.id,provider:'shell'});
      assert.equal(terminal.statusCode,200);
    }
    const operationId=randomUUID(),command={type:'project.remove',projectId:project.id};
    assert.equal((await cmd(command,operationId)).statusCode,200);
    assert.equal((await cmd(command,operationId)).statusCode,200);
    const after=await state();
    assert.deepEqual(after.projects.map((p:any)=>p.id),[other.id]);
    assert.ok(after.workspaces.every((w:any)=>w.projectId===other.id));
    assert.equal(after.terminals.length,0);
    for(const workspace of workspaces)assert.equal(await readFile(join(workspace.path,'.env'),'utf8'),'preserve secret');
    if(kind==='git'){
      const registered=await git(folder,['worktree','list','--porcelain']);
      for(const workspace of workspaces)assert.ok(registered.includes(workspace.path));
    }
    await daemon.app.close();daemon=await createDaemon(data);
    assert.deepEqual((await state()).projects.map((p:any)=>p.id),[other.id]);
    if(kind!=='scratch')assert.equal((await cmd({type:'project.add',path:folder})).statusCode,200);
  }finally{await daemon.app.close();await rm(root,{recursive:true,force:true});}
});

test('failed terminal stop retains all project registrations for retry',async()=>{
  const root=await mkdtemp(join(tmpdir(),'neura-remove-failure-'));
  const daemon=await createDaemon(root);
  const cmd=(command:unknown)=>daemon.app.inject({method:'POST',url:'/v1/commands',headers:{authorization:`Bearer ${daemon.token}`},payload:{operationId:randomUUID(),command}});
  try{
    const project=(await cmd({type:'project.create',name:'keep on failure'})).json();
    const workspace=daemon.store.state().workspaces[0];
    const terminal={id:randomUUID(),workspaceId:workspace.id,provider:'shell' as const,status:'running' as const,createdAt:new Date().toISOString(),cols:80,rows:24};
    // A running record without an owned process cannot be safely forgotten.
    daemon.store.put('terminals',terminal);
    assert.equal((await cmd({type:'project.remove',projectId:project.id})).json().error,'terminal_missing');
    assert.equal(daemon.store.state().projects.length,1);
    assert.equal(daemon.store.state().workspaces.length,1);
    assert.equal(daemon.store.state().terminals.length,1);
    daemon.store.put('terminals',{...terminal,status:'exited'});
    assert.equal((await cmd({type:'project.remove',projectId:project.id})).statusCode,200);
    assert.equal(daemon.store.state().projects.length,0);
  }finally{await daemon.app.close();await rm(root,{recursive:true,force:true});}
});
