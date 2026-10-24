import {test} from 'node:test';
import assert from 'node:assert/strict';
import {mkdtemp,mkdir,writeFile,rm,readFile} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {randomUUID} from 'node:crypto';
import {git,syncDefault,fetchDefault} from '../../apps/daemon/src/workspace.ts';
import {createDaemon} from '../../apps/daemon/src/server.ts';

test('remote default: fresh worktrees, safe root updates, changed default and offline failure',async()=>{
  const dir=await mkdtemp(join(tmpdir(),'neura-remote-')),remote=join(dir,'remote'),repo=join(dir,'repo');
  await mkdir(remote);await git(remote,['init','-b','main']);
  await git(remote,['config','user.name','Test']);await git(remote,['config','user.email','test@example.invalid']);
  await writeFile(join(remote,'file'),'initial');await git(remote,['add','.']);await git(remote,['commit','-m','initial']);
  await git(dir,['clone',remote,repo]);
  const daemon=await createDaemon(join(dir,'data'));
  const cmd=(command:unknown)=>daemon.app.inject({method:'POST',url:'/v1/commands',headers:{authorization:`Bearer ${daemon.token}`},payload:{operationId:randomUUID(),command}});
  try {
    const project=(await cmd({type:'project.add',path:repo})).json();
    const state=(await daemon.app.inject({url:'/v1/state',headers:{authorization:`Bearer ${daemon.token}`}})).json();
    const root=state.workspaces.find((w:{kind:string})=>w.kind==='root');
    await writeFile(join(remote,'file'),'merged');await git(remote,['commit','-am','merged elsewhere']);
    const head=(await git(remote,['rev-parse','HEAD'])).trim();
    const response=await cmd({type:'workspace.create',projectId:project.id});assert.equal(response.statusCode,200,response.body);
    assert.equal((await git(response.json().path,['rev-parse','HEAD'])).trim(),head);
    assert.equal(await readFile(join(repo,'file'),'utf8'),'initial');
    assert.equal((await cmd({type:'workspace.sync-default',workspaceId:response.json().id})).json().error,'root_required');
    const updated=await cmd({type:'workspace.sync-default',workspaceId:root.id});assert.equal(updated.statusCode,200,updated.body);
    assert.equal(await readFile(join(repo,'file'),'utf8'),'merged');
    await writeFile(join(repo,'file'),'dirty');
    await assert.rejects(syncDefault(repo),{code:'workspace_dirty'});
    assert.equal(await readFile(join(repo,'file'),'utf8'),'dirty');
    await git(repo,['restore','file']);
    await git(repo,['-c','user.name=Test','-c','user.email=test@example.invalid','commit','--allow-empty','-m','local']);
    const local=await git(repo,['rev-parse','HEAD']);
    await assert.rejects(syncDefault(repo),{code:'local_commits'});
    assert.equal(await git(repo,['rev-parse','HEAD']),local);
    await git(remote,['switch','-c','trunk']);
    assert.equal((await fetchDefault(repo)).branch,'trunk');
    await syncDefault(repo);
    assert.equal((await git(repo,['branch','--show-current'])).trim(),'trunk');
    assert.equal(await git(repo,['rev-parse','main']),local);
    // Ignored files must survive even when the new remote tree starts tracking them.
    await writeFile(join(repo,'.git','info','exclude'),'secret\n');
    await writeFile(join(repo,'secret'),'keep me');
    await writeFile(join(remote,'secret'),'remote');
    await git(remote,['add','secret']);await git(remote,['commit','-m','track secret']);
    await assert.rejects(syncDefault(repo),{code:'ignored_collision'});
    assert.equal(await readFile(join(repo,'secret'),'utf8'),'keep me');
    await rm(join(repo,'secret'));
    // A checked-out default branch in another worktree cannot be stolen.
    await git(repo,['switch','main']);
    await git(repo,['worktree','add',join(dir,'occupied'),'trunk']);
    await assert.rejects(syncDefault(repo));
    assert.equal((await git(repo,['branch','--show-current'])).trim(),'main');
    await git(repo,['remote','set-url','origin',join(dir,'missing')]);
    const failed=await cmd({type:'workspace.create',projectId:project.id});assert.notEqual(failed.statusCode,200);
    const explicit=await cmd({type:'workspace.create',projectId:project.id,baseRef:'HEAD'});assert.equal(explicit.statusCode,200);
  } finally {await daemon.app.close();await rm(dir,{recursive:true,force:true});}
});

test('slow workspace fetches do not block interactive commands; sync rechecks edits',async()=>{
  const dir=await mkdtemp(join(tmpdir(),'neura-fetch-queue-')),repo=join(dir,'repo');
  await mkdir(repo);await git(repo,['init','-b','main']);
  await git(repo,['config','user.name','Test']);await git(repo,['config','user.email','test@example.invalid']);
  await writeFile(join(repo,'file'),'initial');await git(repo,['add','.']);await git(repo,['commit','-m','initial']);
  const commit=(await git(repo,['rev-parse','HEAD'])).trim();
  let release!:()=>void,started!:()=>void;
  let gate=Promise.resolve();
  const daemon=await createDaemon(join(dir,'data'),undefined,undefined,async()=>{started();await gate;return {branch:'main',commit};});
  const cmd=(command:unknown,operationId=randomUUID())=>daemon.app.inject({method:'POST',url:'/v1/commands',headers:{authorization:`Bearer ${daemon.token}`},payload:{operationId,command}});
  try {
    const project=(await cmd({type:'project.add',path:repo})).json();
    const root=daemon.store.list<{id:string}>('workspaces')[0]!;
    for(const type of ['workspace.create','workspace.sync-default']){
      gate=new Promise<void>(resolve=>{release=resolve;});
      const began=new Promise<void>(resolve=>{started=resolve;});
      const command=type==='workspace.create'?{type,projectId:project.id}:{type,workspaceId:root.id};
      const operationId=randomUUID();
      const pending=cmd(command,operationId).then(response=>response);
      await began;
      try {
        // Invalid terminal IDs still exercise the real input/resize/stop queue.
        // They must return immediately instead of waiting for the network gate.
        const terminalId=randomUUID(),clientId=randomUUID();
        for(const command of [
          {type:'terminal.input',terminalId,clientId,data:'x'},
          {type:'terminal.resize',terminalId,clientId,cols:80,rows:24},
          {type:'terminal.stop',terminalId},
        ]){
          const response=await Promise.race([cmd(command),new Promise<never>((_,reject)=>{const timer=setTimeout(()=>reject(new Error('interactive command blocked by fetch')),1500);timer.unref();})]);
          assert.ok(response.statusCode<500,response.body);
        }
        const file=(await daemon.app.inject({url:`/v1/workspaces/${root.id}/file?path=file`,headers:{authorization:`Bearer ${daemon.token}`}})).json();
        const saved=await Promise.race([cmd({type:'file.save',workspaceId:root.id,path:'file',content:'edited during fetch',expectedHash:file.hash}),new Promise<never>((_,reject)=>{const timer=setTimeout(()=>reject(new Error('save blocked by fetch')),1500);timer.unref();})]);
        assert.equal(saved.statusCode,200,saved.body);
      } finally {release();}
      const response=await pending;
      if(type==='workspace.create')assert.equal(response.statusCode,200,response.body);
      else assert.equal(response.json().error,'workspace_dirty');
      assert.equal(await readFile(join(repo,'file'),'utf8'),'edited during fetch');
      const replay=await cmd(command,operationId);assert.equal(replay.body,response.body);
      await git(repo,['restore','file']);
    }
  } finally {release?.();await daemon.app.close();await rm(dir,{recursive:true,force:true});}
});
