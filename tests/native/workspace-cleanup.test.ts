import {test} from 'node:test';
import assert from 'node:assert/strict';
import {mkdtemp,mkdir,writeFile,rm,access} from 'node:fs/promises';
import {randomUUID} from 'node:crypto';
import {createDaemon} from '../../apps/daemon/src/server.ts';
import {git} from '../../apps/daemon/src/workspace.ts';
import {GitHub} from '../../apps/daemon/src/github.ts';

test('cleanup requires an exactly matching merged PR head, including squash merges',async()=>{
  let state='MERGED',head='a'.repeat(40);
  const service=new GitHub(async(_path,args)=>{assert.deepEqual(args,['pr','view','7','--repo','owner/repo','--json','state,headRefOid']);return JSON.stringify({state,headRefOid:head});},async()=> 'https://github.com/owner/repo.git');
  await service.verifyCleanup('/repo',7,head);
  state='OPEN';await assert.rejects(service.verifyCleanup('/repo',7,head),{code:'workspace_unmerged'});
  state='MERGED';await assert.rejects(service.verifyCleanup('/repo',7,'b'.repeat(40)),{code:'workspace_unmerged'});
});

test('safe cleanup preserves self, roots, unfinished work, dirty/ignored files and changed HEAD; removes only verified worktree',async()=>{
  const root=await mkdtemp('/tmp/neura-cleanup-'),repo=root+'/repo';await mkdir(repo);
  await git(repo,['init','-b','main']);await git(repo,['config','user.name','Test']);await git(repo,['config','user.email','test@example.invalid']);
  await writeFile(repo+'/.gitignore','node_modules/\n.env\n');await writeFile(repo+'/file','initial');await git(repo,['add','.']);await git(repo,['commit','-m','initial']);
  await git(repo,['remote','add','origin','https://github.com/owner/repo.git']);
  const expectedHead=(await git(repo,['rev-parse','HEAD'])).trim();
  const github=new GitHub(async()=>JSON.stringify({state:'MERGED',headRefOid:expectedHead}));
  const d=await createDaemon(root+'/data',github);
  const command=async(c:unknown)=>d.app.inject({method:'POST',url:'/v1/commands',headers:{authorization:`Bearer ${d.token}`},payload:{operationId:randomUUID(),command:c}});
  try{
    const project=(await command({type:'project.add',path:repo})).json();
    const caller=d.store.state().workspaces[0] as {id:string};
    const target=(await command({type:'workspace.create',projectId:project.id,name:'done',baseRef:'HEAD',skipStartup:true})).json();
    const cleanup={callerWorkspaceId:caller.id,expectedHead,mergedPR:7};
    const deletion={type:'workspace.delete',workspaceId:target.id,stopTerminals:true,discardChanges:false,cleanup};
    const reject=async(c:unknown,code:string)=>{const r=await command(c);assert.equal(r.statusCode,409,r.body);assert.equal(r.json().error,code);await access(target.path);};
    await reject({...deletion,cleanup:{...cleanup,callerWorkspaceId:target.id}},'workspace_self_cleanup');
    assert.equal((await command({...deletion,workspaceId:caller.id})).json().error,'worktree_required');
    await reject({...deletion,discardChanges:true},'workspace_cleanup_options');
    await reject({...deletion,cleanup:{...cleanup,expectedHead:'b'.repeat(40)}},'workspace_head_changed');
    const task={id:randomUUID(),workspaceId:target.id,terminalId:randomUUID(),name:'worker',status:'working',turnId:randomUUID(),pending:[],requests:[],updatedAt:''};d.store.put('agents',task);
    await reject(deletion,'workspace_task_unfinished');d.store.put('agents',{...task,status:'idle',turnId:undefined,pending:[{id:randomUUID(),text:'unread instruction'}]});
    await reject(deletion,'workspace_task_unfinished');d.store.put('agents',{...task,status:'idle',turnId:undefined});
    await writeFile(target.path+'/file','changed');await reject(deletion,'workspace_dirty');await git(target.path,['restore','file']);
    await writeFile(target.path+'/.env','secret');await reject(deletion,'workspace_ignored_files');await rm(target.path+'/.env');
    await mkdir(target.path+'/node_modules');await writeFile(target.path+'/node_modules/cache','generated');await reject(deletion,'workspace_ignored_files');await rm(target.path+'/node_modules',{recursive:true});
    assert.equal((await command(deletion)).statusCode,200);
    assert.equal(d.store.state().workspaces.some((w:any)=>w.id===target.id),false);
    await assert.rejects(access(target.path));
    assert.ok((await git(repo,['branch','--list',target.branch])).trim(),'retain committed branch');
  }finally{await d.app.close();await rm(root,{recursive:true,force:true});}
});
