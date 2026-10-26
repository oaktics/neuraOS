import {test} from 'node:test';
import assert from 'node:assert/strict';
import {mkdtemp,mkdir,writeFile,readFile,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {randomUUID} from 'node:crypto';
import {GitHub,pullRequestNumber} from '../../apps/daemon/src/github.ts';
import {git} from '../../apps/daemon/src/workspace.ts';
import {createDaemon} from '../../apps/daemon/src/server.ts';

const pr={number:17,title:'Restore old work',state:'CLOSED',headRefName:'deleted-branch'};
test('PR selectors accept numbers and same-repository URLs, rejecting mismatches and unsafe input',()=>{
  for(const input of ['17','#17',' https://github.com/OWNER/repo/pull/17/files#diff-1 '])assert.equal(pullRequestNumber(input,'owner/repo'),17);
  assert.throws(()=>pullRequestNumber('https://github.com/other/repo/pull/17','owner/repo'),{code:'pr_repository_mismatch'});
  for(const input of ['0','-1','1e2','9007199254740992','--help','https://evil.test/owner/repo/pull/17','https://github.com/owner/repo/issues/17'])assert.throws(()=>pullRequestNumber(input,'owner/repo'),{code:'invalid_pr'});
});
test('PR search includes every state and resolves number/URL beyond the first list page',async()=>{
  const calls:string[][]=[];
  const service=new GitHub(async(_,args)=>{calls.push(args);return JSON.stringify(args[1]==='view'?pr:[pr]);},async()=> 'https://github.com/owner/repo.git');
  assert.equal((await service.pullRequests('/repo')).pullRequests[0].state,'CLOSED');
  assert.ok(calls[0].includes('all'));
  await service.pullRequests('/repo','old work');assert.deepEqual(calls.at(-1)?.slice(-2),['--search','old work']);
  await service.pullRequests('/repo','#17');assert.equal(calls.at(-1)?.[1],'view');
  await service.pullRequests('/repo','https://github.com/owner/repo/pull/17');assert.equal(calls.at(-1)?.[2],'17');
  await assert.rejects(service.pullRequests('/repo','https://github.com/elsewhere/repo/pull/17'),{code:'pr_repository_mismatch'});
});
test('closed/merged PRs with deleted source branches create independent worktrees, preserve root, replay safely and fail without fallback',{timeout:30000},async()=>{
  const dir=await mkdtemp(join(tmpdir(),'neura-pr-')),remote=join(dir,'remote'),repo=join(dir,'repo');
  await mkdir(remote);await git(remote,['init','-b','main']);
  await git(remote,['config','user.name','Test']);await git(remote,['config','user.email','test@example.invalid']);
  await writeFile(join(remote,'file'),'main');await git(remote,['add','.']);await git(remote,['commit','-m','main']);
  await git(dir,['clone',remote,repo]);
  await git(remote,['switch','-c','deleted-branch']);
  await writeFile(join(remote,'file'),'PR content');await git(remote,['commit','-am','PR']);
  const head=(await git(remote,['rev-parse','HEAD'])).trim();
  await git(remote,['update-ref','refs/pull/17/head',head]);
  await git(remote,['switch','main']);await git(remote,['branch','-D','deleted-branch']);
  let state='CLOSED',release:(()=>void)|undefined,entered:(()=>void)|undefined,gate:Promise<void>|undefined;
  const service=new GitHub(async()=>{entered?.();await gate;return JSON.stringify({...pr,state});},async(root,args)=>args[0]==='remote'?'https://github.com/owner/repo.git':git(root,args));
  const daemon=await createDaemon(join(dir,'data'),service);
  const cmd=(command:unknown,operationId=randomUUID())=>daemon.app.inject({method:'POST',url:'/v1/commands',headers:{authorization:`Bearer ${daemon.token}`},payload:{operationId,command}});
  try {
    const project=(await cmd({type:'project.add',path:repo})).json();
    const root=daemon.store.list<{id:string;kind:string}>('workspaces').find(w=>w.kind==='root')!;
    const rootHead=(await git(repo,['rev-parse','HEAD'])).trim();
    const listed=await daemon.app.inject({url:`/v1/projects/${project.id}/pull-requests?query=%2317`,headers:{authorization:`Bearer ${daemon.token}`}});
    assert.equal(listed.statusCode,200,listed.body);assert.equal(listed.json().pullRequests[0].number,17);
    const denied=await daemon.app.inject({url:`/v1/projects/${project.id}/pull-requests?query=%2317`});assert.equal(denied.statusCode,401);
    for(state of ['OPEN','CLOSED','MERGED']){
      const started=new Promise<void>(resolve=>{entered=resolve;});gate=new Promise<void>(resolve=>{release=resolve;});
      const command={type:'workspace.create',projectId:project.id,pullRequest:'#17'},id=randomUUID();
      const pending=cmd(command,id);void pending.then(()=>{});await started;
      // Network fetching must not occupy the interactive mutation queue.
      const file=(await daemon.app.inject({url:`/v1/workspaces/${root.id}/file?path=file`,headers:{authorization:`Bearer ${daemon.token}`}})).json();
      const saved=await cmd({type:'file.save',workspaceId:root.id,path:'file',content:'dirty root',expectedHash:file.hash});assert.equal(saved.statusCode,200,saved.body);
      release!();const response=await pending;assert.equal(response.statusCode,200,response.body);
      const worktree=response.json();assert.equal((await git(worktree.path,['rev-parse','HEAD'])).trim(),head);
      assert.match(worktree.branch,/^neura\//);assert.notEqual(worktree.branch,pr.headRefName);
      assert.equal(await readFile(join(repo,'file'),'utf8'),'dirty root');assert.equal((await git(repo,['rev-parse','HEAD'])).trim(),rootHead);
      assert.equal((await cmd(command,id)).body,response.body);
      assert.equal((await git(repo,['for-each-ref','--format=%(refname)','refs/neura/pr-fetch/'])).trim(),'');
    }
    assert.equal((await cmd({type:'workspace.create',projectId:project.id,baseRef:'HEAD',pullRequest:'17'})).json().error,'invalid_source');
    assert.equal((await cmd({type:'workspace.create',projectId:project.id,pullRequest:'https://github.com/other/repo/pull/17'})).json().error,'pr_repository_mismatch');
    await git(remote,['update-ref','-d','refs/pull/17/head']);
    const before=daemon.store.list('workspaces').length;
    const failed=await cmd({type:'workspace.create',projectId:project.id,pullRequest:'17'});assert.notEqual(failed.statusCode,200);
    assert.equal(daemon.store.list('workspaces').length,before);
  } finally {release?.();await daemon.app.close();await rm(dir,{recursive:true,force:true});}
});
