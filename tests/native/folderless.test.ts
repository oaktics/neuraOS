import {test} from 'node:test';
import assert from 'node:assert/strict';
import {mkdtemp,mkdir,writeFile,readFile,rm,stat} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {randomUUID} from 'node:crypto';
import {createDaemon} from '../../apps/daemon/src/server.ts';
import {git} from '../../apps/daemon/src/workspace.ts';

test('folderless projects persist, isolate cwd, and retain live sessions when attaching a folder',async()=>{
  const root=await mkdtemp(join(tmpdir(),'neura-free-')),data=join(root,'data'),folder=join(root,'folder');
  await mkdir(folder);await writeFile(join(folder,'note.txt'),'attached');
  let daemon=await createDaemon(data);
  const get=(url:string)=>daemon.app.inject({url,headers:{authorization:`Bearer ${daemon.token}`}});
  const cmd=(command:unknown,operationId=randomUUID())=>daemon.app.inject({method:'POST',url:'/v1/commands',headers:{authorization:`Bearer ${daemon.token}`},payload:{operationId,command}});
  try {
    assert.equal((await cmd({type:'project.create',name:'  '})).statusCode,400);
    const operationId=randomUUID(),command={type:'project.create',name:'旅行計画'};
    const project=(await cmd(command,operationId)).json();
    assert.equal((await cmd(command,operationId)).json().id,project.id);
    assert.equal(project.folderless,true);
    assert.equal((await stat(project.path)).mode&0o777,0o700);
    const other=(await cmd({type:'project.create',name:'別の作業'})).json();
    assert.notEqual(other.path,project.path);
    const scratch=(await get('/v1/state')).json().workspaces.find((w:any)=>w.projectId===project.id);
    assert.equal(scratch.kind,'scratch');
    assert.equal((await cmd({type:'project.add',path:scratch.path})).json().error,'managed_folder');
    assert.equal((await cmd({type:'project.attach',projectId:project.id,path:scratch.path})).statusCode,409);
    assert.equal((await get(`/v1/workspaces/${scratch.id}/files`)).json().error,'folder_required');
    assert.equal((await get(`/v1/workspaces/${scratch.id}/git`)).json().error,'git_required');
    assert.equal((await get(`/v1/workspaces/${scratch.id}/checks`)).json().state,'unsupported');
    assert.equal((await cmd({type:'workspace.create',projectId:project.id})).json().error,'git_required');
    const terminal=(await cmd({type:'terminal.open',workspaceId:scratch.id,provider:'shell'})).json();
    assert.ok(terminal.id);
    const attached=(await cmd({type:'project.attach',projectId:project.id,path:folder})).json();
    assert.equal(attached.id,project.id);assert.equal(attached.name,project.name);assert.equal(attached.folderless,false);
    const state=(await get('/v1/state')).json();
    assert.deepEqual(state.workspaces.find((w:any)=>w.id===scratch.id),scratch);
    assert.equal(state.terminals.find((t:any)=>t.id===terminal.id).status,'running');
    const linked=state.workspaces.find((w:any)=>w.projectId===project.id&&w.kind==='folder');
    assert.equal((await get(`/v1/workspaces/${linked.id}/file?path=note.txt`)).json().content,'attached');
    await cmd({type:'terminal.input',terminalId:terminal.id,clientId:randomUUID(),data:"printf retained > retained.txt\n"});
    for(let i=0;i<60;i++){
      if(await readFile(join(scratch.path,'retained.txt'),'utf8').then(s=>s==='retained',()=>false))break;
      await new Promise(r=>setTimeout(r,50));
    }
    assert.equal(await readFile(join(scratch.path,'retained.txt'),'utf8'),'retained');
    assert.equal((await cmd({type:'project.attach',projectId:project.id,path:folder})).statusCode,409);
    assert.equal((await cmd({type:'project.attach',projectId:other.id,path:folder})).statusCode,409);
    // Reopening the attached folder must not repurpose the scratch workspace.
    await cmd({type:'project.add',path:folder});
    assert.deepEqual((await get('/v1/state')).json().workspaces.find((w:any)=>w.id===scratch.id),scratch);
    await git(folder,['init','-b','main']);
    const upgraded=(await get('/v1/state')).json();
    assert.equal(upgraded.workspaces.find((w:any)=>w.id===linked.id).kind,'root');
    assert.equal(upgraded.workspaces.find((w:any)=>w.id===scratch.id).kind,'scratch');
    await daemon.app.close();daemon=await createDaemon(data);
    const restored=(await get('/v1/state')).json();
    assert.equal(restored.projects.find((p:any)=>p.id===project.id).folderless,false);
    assert.equal(restored.workspaces.find((w:any)=>w.id===scratch.id).path,scratch.path);
    assert.equal(restored.terminals.find((t:any)=>t.id===terminal.id).status,'interrupted');
  } finally {await daemon.app.close();await rm(root,{recursive:true,force:true});}
});

test('attaching an existing Git repository enables worktrees without changing scratch',async()=>{
  const root=await mkdtemp(join(tmpdir(),'neura-free-git-')),repo=join(root,'repo');
  await mkdir(repo);await git(repo,['init','-b','main']);
  await git(repo,['-c','user.name=Test','-c','user.email=test@example.invalid','commit','--allow-empty','-m','initial']);
  const daemon=await createDaemon(join(root,'data'));
  const cmd=(command:unknown)=>daemon.app.inject({method:'POST',url:'/v1/commands',headers:{authorization:`Bearer ${daemon.token}`},payload:{operationId:randomUUID(),command}});
  try{
    const project=(await cmd({type:'project.create',name:'開発'})).json();
    assert.equal((await cmd({type:'project.attach',projectId:project.id,path:join(root,'missing')})).statusCode,500);
    const attached=(await cmd({type:'project.attach',projectId:project.id,path:repo})).json();
    assert.equal(attached.isGit,true);
    assert.equal((await cmd({type:'workspace.create',projectId:project.id,baseRef:'HEAD'})).statusCode,200);
  }finally{await daemon.app.close();await rm(root,{recursive:true,force:true});}
});
