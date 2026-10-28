import {test} from 'node:test';
import assert from 'node:assert/strict';
import {mkdtemp,mkdir,writeFile,readFile,rm,symlink} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {randomUUID} from 'node:crypto';
import {createDaemon} from '../../apps/daemon/src/server.ts';
import {git} from '../../apps/daemon/src/workspace.ts';
import {detectSetup,setupPath} from '../../apps/daemon/src/worktree-setup.ts';

test('setup discovery excludes escaped symlinks and paths',async()=>{
  const root=await mkdtemp(join(tmpdir(),'neura-detect-'));
  try{
    await mkdir(join(root,'repo'));await writeFile(join(root,'outside.sh'),'exit 0');
    await symlink(join(root,'outside.sh'),join(root,'repo','setup.sh'));
    assert.deepEqual(await detectSetup(join(root,'repo')),[]);
    await assert.rejects(setupPath(join(root,'repo'),'../outside.sh'));
    await assert.rejects(setupPath(join(root,'repo'),join(root,'outside.sh')));
    await writeFile(join(root,'repo','worktree-setup.sh'),'exit 0');
    assert.deepEqual(await detectSetup(join(root,'repo')),['worktree-setup.sh']);
  }finally{await rm(root,{recursive:true,force:true});}
});

test('setup persists, runs before startup, stays responsive, records failures and retries without replay',async()=>{
  const root=await mkdtemp(join(tmpdir(),'neura-setup-')),repo=join(root,'repo'),data=join(root,'data');
  await mkdir(repo);await git(repo,['init','-b','main']);
  await git(repo,['config','user.name','Test']);await git(repo,['config','user.email','test@example.invalid']);
  await writeFile(join(repo,'worktree-setup.sh'),'sleep 0.3\nprintf "ready" > ready.txt\necho setup-done\n');
  await git(repo,['add','.']);await git(repo,['commit','-m','initial']);
  let daemon=await createDaemon(data);
  const cmd=(command:unknown,operationId=randomUUID())=>daemon.app.inject({method:'POST',url:'/v1/commands',headers:{authorization:`Bearer ${daemon.token}`},payload:{operationId,command}});
  const state=async()=>(await daemon.app.inject({url:'/v1/state',headers:{authorization:`Bearer ${daemon.token}`}})).json();
  const finished=async(id:string)=>{
    for(let i=0;i<150;i++){
      const w=(await state()).workspaces.find((w:any)=>w.id===id);
      if(w.setup.status!=='running')return w;
      await new Promise(r=>setTimeout(r,20));
    }
    throw new Error('setup did not finish');
  };
  try{
    const project=(await cmd({type:'project.add',path:repo})).json();
    const detected=await daemon.app.inject({url:`/v1/projects/${project.id}/setup-scripts`,headers:{authorization:`Bearer ${daemon.token}`}});
    assert.deepEqual(detected.json().scripts,['worktree-setup.sh']);
    const create={type:'workspace.create',projectId:project.id,baseRef:'HEAD'};
    assert.equal((await cmd(create)).json().setup,undefined); // detection never opts in
    assert.equal((await cmd({type:'project.set-worktree-setup',projectId:project.id,script:'missing.sh'})).statusCode,400);
    assert.equal((await cmd({type:'project.set-worktree-setup',projectId:project.id,script:'worktree-setup.sh'})).statusCode,200);
    await cmd({type:'project.set-worktree-startup',projectId:project.id,providers:['shell']});
    await daemon.app.close();daemon=await createDaemon(data);
    assert.equal((await state()).projects[0].worktreeSetup,'worktree-setup.sh');
    const id=randomUUID(),created=(await cmd(create,id)).json();
    assert.equal(created.setup.status,'running');assert.equal((await state()).terminals.length,0);
    assert.equal((await cmd({type:'terminal.open',workspaceId:id,provider:'shell'})).statusCode,409);
    assert.equal((await cmd({type:'workspace.delete',workspaceId:id,discardChanges:true})).statusCode,409);
    const done=await finished(id);assert.equal(done.setup.status,'succeeded');assert.match(done.setup.output,/setup-done/);
    assert.equal(await readFile(join(created.path,'ready.txt'),'utf8'),'ready');
    assert.equal((await state()).terminals.length,1);
    assert.deepEqual((await cmd(create,id)).json(),created);
    await cmd({type:'terminal.stop',terminalId:(await state()).terminals[0].id});
    for(let i=0;i<150&&(await state()).terminals.some((t:any)=>t.status==='running');i++)await new Promise(r=>setTimeout(r,20));
    await writeFile(join(created.path,'worktree-setup.sh'),'echo broken; exit 7');
    const retryId=randomUUID();assert.equal((await cmd({type:'workspace.setup',workspaceId:id},retryId)).statusCode,200);
    assert.equal((await finished(id)).setup.status,'failed');
    assert.match((await finished(id)).setup.error,/7/);
    await writeFile(join(created.path,'worktree-setup.sh'),'echo recovered');
    await cmd({type:'workspace.setup',workspaceId:id},retryId); // same operation cannot re-execute
    assert.equal((await state()).workspaces.find((w:any)=>w.id===id).setup.status,'failed');
    await cmd({type:'workspace.setup',workspaceId:id});assert.equal((await finished(id)).setup.status,'succeeded');
    await writeFile(join(repo,'worktree-setup.sh'),'sleep 30');
    await git(repo,['add','.']);await git(repo,['commit','-m','slow setup']);
    const slow=(await cmd({...create,skipStartup:true})).json();
    assert.equal(slow.setup.status,'running');
    await daemon.app.close();daemon=await createDaemon(data);
    assert.equal((await state()).workspaces.find((w:any)=>w.id===slow.id).setup.status,'failed');
    await writeFile(join(repo,'custom.sh'),'echo custom');
    await cmd({type:'project.set-worktree-setup',projectId:project.id,script:'custom.sh'});
    const missing=(await cmd({...create,skipStartup:true})).json();
    assert.equal((await finished(missing.id)).setup.status,'failed'); // uncommitted script absent from new worktree
    await cmd({type:'project.set-worktree-setup',projectId:project.id,script:''});
    assert.equal((await cmd({...create,skipStartup:true})).json().setup,undefined);
  }finally{await daemon.app.close();await rm(root,{recursive:true,force:true});}
});
