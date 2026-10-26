import {test} from 'node:test';
import assert from 'node:assert/strict';
import {mkdtemp,mkdir,writeFile,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {randomUUID} from 'node:crypto';
import {createDaemon} from '../../apps/daemon/src/server.ts';
import {git} from '../../apps/daemon/src/workspace.ts';

test('project startup persists, applies only to new worktrees, isolates failures and does not replay',async()=>{
  const root=await mkdtemp(join(tmpdir(),'neura-startup-')),repo=join(root,'repo'),other=join(root,'other'),data=join(root,'data');
  for(const path of [repo,other]){
    await mkdir(path);await git(path,['init','-b','main']);
    await git(path,['config','user.name','Test']);await git(path,['config','user.email','test@example.invalid']);
    await writeFile(join(path,'hello.txt'),'hello');await git(path,['add','.']);await git(path,['commit','-m','initial']);
  }
  const oldCodex=process.env.NEURA_CODEX_PATH;
  process.env.NEURA_CODEX_PATH=join(root,'missing-codex');
  let daemon=await createDaemon(data);
  const cmd=(command:unknown,operationId=randomUUID())=>daemon.app.inject({method:'POST',url:'/v1/commands',headers:{authorization:`Bearer ${daemon.token}`},payload:{operationId,command}});
  const state=async()=>(await daemon.app.inject({url:'/v1/state',headers:{authorization:`Bearer ${daemon.token}`}})).json();
  try{
    const project=(await cmd({type:'project.add',path:repo})).json();
    const second=(await cmd({type:'project.add',path:other})).json();
    const create={type:'workspace.create',projectId:project.id,baseRef:'HEAD'};
    assert.equal((await cmd(create)).statusCode,200);
    assert.equal((await state()).terminals.length,0);
    assert.equal((await cmd({type:'project.set-worktree-startup',projectId:project.id,providers:['unknown']})).statusCode,400);
    assert.equal((await cmd({type:'project.set-worktree-startup',projectId:project.id,providers:['shell','shell']})).statusCode,400);
    assert.equal((await cmd({type:'project.set-worktree-startup',projectId:randomUUID(),providers:[]})).statusCode,404);
    assert.equal((await cmd({type:'project.set-worktree-startup',projectId:project.id,providers:['codex','shell']})).statusCode,200);
    await daemon.app.close();daemon=await createDaemon(data);
    assert.deepEqual((await state()).projects.find((p:any)=>p.id===project.id).worktreeStartup,['codex','shell']);
    assert.deepEqual((await cmd({type:'project.add',path:repo})).json().worktreeStartup,['codex','shell']);
    const operationId=randomUUID(),created=await cmd(create,operationId);
    assert.equal(created.statusCode,200);
    const workspace=created.json();assert.equal(workspace.startupErrors.length,1);assert.match(workspace.startupErrors[0],/Codex/);
    const terminals=(await state()).terminals;
    assert.equal(terminals.length,1);assert.equal(terminals[0].workspaceId,workspace.id);assert.equal(terminals[0].provider,'shell');
    assert.deepEqual((await cmd(create,operationId)).json(),workspace);
    assert.equal((await state()).terminals.length,1);
    assert.equal((await cmd({...create,projectId:second.id})).statusCode,200);
    assert.equal((await state()).terminals.length,1);
    await cmd({type:'project.set-worktree-startup',projectId:project.id,providers:[]});
    assert.deepEqual((await cmd(create)).json().startupErrors,[]);
    assert.equal((await state()).terminals.length,1);
  }finally{
    if(oldCodex===undefined)delete process.env.NEURA_CODEX_PATH;else process.env.NEURA_CODEX_PATH=oldCodex;
    await daemon.app.close();await rm(root,{recursive:true,force:true});
  }
});
