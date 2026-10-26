import {test} from 'node:test';
import assert from 'node:assert/strict';
import {mkdtemp,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {randomUUID} from 'node:crypto';
import {GitHub,githubRepository} from '../../apps/daemon/src/github.ts';
import {createDaemon} from '../../apps/daemon/src/server.ts';
import {Command,Fault} from '../../apps/daemon/src/contracts.ts';

const head='a'.repeat(40),otherHead='b'.repeat(40),workspaceId=randomUUID();
const target={workspaceId,repository:'owner/repo',branch:'feature/test',expectedHead:head};
function fixture(){
  const calls:{kind:string;args:string[]}[]=[];
  const state={branch:target.branch,head,remote:'https://github.com/owner/repo.git',pushRemote:'git@github.com:owner/repo.git',remoteHead:head,hasPR:true,unresolved:false,merged:true,fail:false,
    pr:{number:17,title:'A PR',body:'Description',url:'https://github.com/owner/repo/pull/17',state:'OPEN',isDraft:false,headRefName:target.branch,headRefOid:head,baseRefName:'main',mergeStateStatus:'CLEAN',reviewDecision:'APPROVED',headRepository:{name:'repo'},headRepositoryOwner:{login:'owner'},author:{login:'alice'},additions:42,deletions:7,changedFiles:1,files:[{path:'src/main.ts',additions:42,deletions:7}],statusCheckRollup:[{name:'test',status:'COMPLETED',conclusion:'SUCCESS',detailsUrl:'https://github.com/owner/repo/actions/runs/1'}]}};
  const git=async(_root:string,args:string[])=>{
    calls.push({kind:'git',args});
    if(args[0]==='remote')return args.includes('--push')?state.pushRemote:state.remote;
    if(args[0]==='branch')return state.branch;
    if(args[0]==='rev-parse')return state.head;
    if(args.includes('push'))return '';
    throw new Error(`unexpected git: ${args}`);
  };
  const run=async(_root:string,args:string[])=>{
    calls.push({kind:'gh',args});
    if(state.fail)throw new Fault('github_failed','offline',502);
    if(args[0]==='pr')return JSON.stringify(state.pr);
    assert.equal(args[0],'api');assert.equal(args[2],'github.com');
    const endpoint=args[3];let value:unknown;
    if(endpoint==='repos/owner/repo')value={full_name:'owner/repo',default_branch:'main',allow_merge_commit:true,allow_squash_merge:true,allow_rebase_merge:false};
    else if(endpoint.startsWith('repos/owner/repo/pulls?')){
      assert.ok(args.includes('--paginate'));assert.ok(args.includes('--slurp'));
      value=[[{number:99,state:'open',head:{ref:target.branch,repo:{full_name:'someone/repo'}}}],[...(state.hasPR?[{number:17,state:'open',head:{ref:target.branch,repo:{full_name:'owner/repo'}}}]:[])]];
    } else if(endpoint.includes('/git/ref/'))value={object:{sha:state.remoteHead}};
    else if(endpoint==='repos/owner/repo/pulls')value={html_url:'https://github.com/owner/repo/pull/18'};
    else if(endpoint.endsWith('/merge'))value={merged:state.merged};
    else if(endpoint==='graphql')value=[{data:{repository:{pullRequest:{reviewThreads:{nodes:[{isResolved:true}]}}}}},{data:{repository:{pullRequest:{reviewThreads:{nodes:[{isResolved:!state.unresolved}]}}}}}];
    else if(endpoint.includes('/reviews?'))value=[[{id:3,user:{login:'reviewer'},body:'',html_url:'https://github.com/owner/repo/pull/17#review-3',submitted_at:'2026-01-02',state:'APPROVED'}]];
    else if(endpoint.includes('/issues/'))value=[[{id:1,user:{login:'alice'},body:'first',html_url:'https://github.com/owner/repo/pull/17#comment-1',created_at:'2026-01-01'}],[{id:2,user:null,body:'next page',html_url:'https://github.com/owner/repo/pull/17#comment-2',created_at:'2026-01-04'}]];
    else if(endpoint.includes('/comments?'))value=[[{id:1,user:{login:'bob'},body:'inline',html_url:'https://github.com/owner/repo/pull/17#discussion-1',created_at:'2026-01-03',path:'src/main.ts',line:null,original_line:12}]];
    else throw new Error(`unexpected gh: ${args}`);
    return JSON.stringify(value);
  };
  return {service:new GitHub(run,git),state,calls};
}
const mergeCommand=()=>Command.parse({type:'github.merge',...target,number:17,method:'squash',expectedPRHead:head}) as Extract<Command,{type:'github.merge'}>;
const createCommand=()=>Command.parse({type:'github.create',...target,title:'Title',body:'Description',base:'main',draft:true}) as Extract<Command,{type:'github.create'}>;
const mutations=(calls:ReturnType<typeof fixture>['calls'])=>calls.filter(c=>c.args.includes('POST')||c.args.includes('PUT')||c.args.includes('push'));

test('GitHub remotes accept canonical SSH/HTTPS and reject other hosts or credentials',()=>{
  for(const url of ['https://github.com/owner/repo.git','git@github.com:owner/repo.git','ssh://git@github.com/owner/repo.git','https://github.com/owner/repo/'])assert.equal(githubRepository(url),'owner/repo');
  for(const url of ['https://github.com.evil/owner/repo','https://token@github.com/owner/repo','https://gitlab.com/owner/repo','/local/path','-evil','https://github.com/owner/repo?x=y'])assert.throws(()=>githubRepository(url));
});
test('status selects the exact head repository and combines all pages of conversation, reviews, and inline comments',async()=>{
  const {service,calls}=fixture(),status=await service.status('/repo');
  assert.equal(status.pullRequest?.number,17);assert.equal(status.pullRequest?.author?.login,'alice');assert.equal(status.pullRequest?.additions,42);assert.deepEqual(status.pullRequest?.files,[{path:'src/main.ts',additions:42,deletions:7}]);assert.deepEqual(status.mergeMethods,['squash','merge']);
  assert.deepEqual(status.pullRequest?.comments.map(c=>c.id),['comment-1','review-3','line-1','comment-2']);
  assert.equal(status.pullRequest?.comments[2].line,12);assert.equal(status.pullRequest?.comments[2].outdated,true);
  assert.equal(status.pullRequest?.checks[0].state,'SUCCESS');assert.equal(status.pullRequest?.unresolvedThreads,0);
  assert.deepEqual(mutations(calls),[]);
});
test('no PR is distinct from GitHub request failure and detached worktrees',async()=>{
  const {service,state}=fixture();state.hasPR=false;assert.equal((await service.status('/repo')).pullRequest,null);
  state.fail=true;await assert.rejects(service.status('/repo',true),{code:'github_failed'});
  state.fail=false;state.branch='';await assert.rejects(service.status('/repo'),{code:'github_detached'});
});
test('push targets the displayed commit and branch without force or arbitrary push destinations',async()=>{
  const {service,state,calls}=fixture();
  const command=Command.parse({type:'github.push',...target}) as Extract<Command,{type:'github.push'}>;
  await service.mutate('/repo',command);
  assert.deepEqual(mutations(calls)[0].args,['-c','remote.origin.mirror=false','push','--no-follow-tags','git@github.com:owner/repo.git',`${head}:refs/heads/feature/test`]);
  calls.length=0;state.pushRemote='git@github.com:someone/repo.git';await assert.rejects(service.mutate('/repo',command),{code:'github_push_remote'});assert.deepEqual(mutations(calls),[]);
  state.pushRemote='git@github.com:owner/repo.git\ngit@github.com:other/repo.git';await assert.rejects(service.mutate('/repo',command),{code:'github_push_remote'});
});
test('PR creation preserves literal multiline body and Draft, and rejects duplicates/unpushed heads',async()=>{
  const {service,state,calls}=fixture();const command=createCommand();
  await assert.rejects(service.mutate('/repo',command),{code:'github_pr_exists'});assert.deepEqual(mutations(calls),[]);
  state.hasPR=false;state.remoteHead=otherHead;await assert.rejects(service.mutate('/repo',command),{code:'github_push_required'});assert.deepEqual(mutations(calls),[]);
  state.remoteHead=head;command.body='@secrets.txt\n$(touch /tmp/nope)\n--admin';
  await service.mutate('/repo',command);
  const args=mutations(calls)[0].args;assert.ok(args.includes(`body=${command.body}`));assert.ok(args.includes('draft=true'));assert.ok(args.includes('base=main'));
});
test('merge rechecks head, review threads, policy state and method, and sends atomic expected SHA',async()=>{
  for(const change of [
    (f:ReturnType<typeof fixture>)=>{f.state.head=otherHead;},
    (f:ReturnType<typeof fixture>)=>{f.state.branch='other';},
    (f:ReturnType<typeof fixture>)=>{f.state.remote='https://github.com/owner/other.git';},
    (f:ReturnType<typeof fixture>)=>{f.state.pr.headRefOid=otherHead;},
    (f:ReturnType<typeof fixture>)=>{f.state.pr.headRepositoryOwner.login='someone';},
    (f:ReturnType<typeof fixture>)=>{f.state.pr.isDraft=true;},
    (f:ReturnType<typeof fixture>)=>{f.state.pr.state='MERGED';},
    (f:ReturnType<typeof fixture>)=>{f.state.pr.mergeStateStatus='BLOCKED';},
    (f:ReturnType<typeof fixture>)=>{f.state.pr.mergeStateStatus='UNKNOWN';},
    (f:ReturnType<typeof fixture>)=>{f.state.pr.reviewDecision='CHANGES_REQUESTED';},
    (f:ReturnType<typeof fixture>)=>{f.state.unresolved=true;},
    (f:ReturnType<typeof fixture>)=>{f.state.fail=true;},
  ]){
    const f=fixture();change(f);await assert.rejects(f.service.mutate('/repo',mergeCommand()));assert.deepEqual(mutations(f.calls),[]);
  }
  const {service,calls,state}=fixture();await assert.rejects(service.mutate('/repo',{...mergeCommand(),method:'rebase'}),{code:'github_merge_method'});
  assert.deepEqual(mutations(calls),[]);await service.mutate('/repo',mergeCommand());
  assert.ok(mutations(calls)[0].args.includes(`sha=${head}`));assert.ok(mutations(calls)[0].args.includes('merge_method=squash'));
  state.merged=false;await assert.rejects(service.mutate('/repo',mergeCommand()),{code:'github_merge_blocked'});
});
test('GitHub HTTP commands retain authentication, validation and durable operation deduplication',async()=>{
  const dir=await mkdtemp(join(tmpdir(),'neura-github-')),f=fixture(),daemon=await createDaemon(dir,f.service);
  const headers={authorization:`Bearer ${daemon.token}`};
  daemon.store.put('workspaces',{id:workspaceId,projectId:randomUUID(),name:'Test',path:'/repo',branch:target.branch,kind:'worktree',createdAt:new Date().toISOString()});
  const payload={operationId:randomUUID(),command:mergeCommand()};
  try {
    for(const url of ['/v1/state','/v1/capabilities']){
      const response=await daemon.app.inject({url,headers});
      assert.equal(response.statusCode,200);assert.equal(response.json().protocolVersion,1);
      assert.deepEqual(response.json().features,['github','workspace.delete','workspace.delete.discard','workspace.delete.stop-terminals','terminal.multiple','provider.usage','terminal.activity','terminal.notifications','github.checks','workspace.remote-default','project.worktree-startup','project.folderless','workspace.from-pr']);
    }
    assert.equal((await daemon.app.inject(`/v1/workspaces/${workspaceId}/github`)).statusCode,401);
    assert.equal((await daemon.app.inject({url:`/v1/workspaces/${workspaceId}/github`,headers})).statusCode,200);
    const send=()=>daemon.app.inject({method:'POST',url:'/v1/commands',headers,payload});
    const results=await Promise.all([send(),send()]);assert.deepEqual(results.map(r=>r.statusCode),[200,200]);assert.equal(mutations(f.calls).length,1);
    assert.equal((await daemon.app.inject({method:'POST',url:'/v1/commands',headers,payload:{...payload,command:{...payload.command,method:'merge'}}})).statusCode,409);
    assert.equal((await daemon.app.inject({method:'POST',url:'/v1/commands',headers,payload:{operationId:randomUUID(),command:{...payload.command,expectedHead:'bad'}}})).statusCode,400);
    await daemon.app.close();
    const restored=await createDaemon(dir,f.service);
    try {assert.equal((await restored.app.inject({method:'POST',url:'/v1/commands',headers,payload})).statusCode,200);assert.equal(mutations(f.calls).length,1);} finally {await restored.app.close();}
  } finally {await daemon.app.close();await rm(dir,{recursive:true,force:true});}
});
test('a slow GitHub command does not block local commands; folders reject GitHub',async()=>{
  const dir=await mkdtemp(join(tmpdir(),'neura-github-queue-'));
  let finish!:()=>void,started!:()=>void;
  const pending=new Promise<void>(resolve=>{finish=resolve;}),entered=new Promise<void>(resolve=>{started=resolve;});
  class SlowGitHub extends GitHub {override async mutate(){started();await pending;return {ok:true,message:'done'};}}
  const daemon=await createDaemon(dir,new SlowGitHub());
  daemon.store.put('workspaces',{id:workspaceId,projectId:randomUUID(),name:'Test',path:'/repo',branch:target.branch,kind:'worktree',createdAt:new Date().toISOString()});
  const headers={authorization:`Bearer ${daemon.token}`};
  const cmd=(command:unknown)=>daemon.app.inject({method:'POST',url:'/v1/commands',headers,payload:{operationId:randomUUID(),command}});
  const slow=cmd(mergeCommand());
  let timeout:ReturnType<typeof setTimeout>|undefined;
  try {
    await entered;
    const local=await Promise.race([cmd({type:'project.add',path:dir}),new Promise<never>((_,reject)=>{timeout=setTimeout(()=>reject(new Error('local commands blocked by network queue')),2000);})]);
    assert.equal(local.statusCode,200);
    const folder=daemon.store.state().workspaces.find(w=>w.kind==='folder')!;
    assert.equal((await daemon.app.inject({url:`/v1/workspaces/${folder.id}/github`,headers})).json().error,'git_required');
    finish();await slow;
    assert.equal((await cmd({...mergeCommand(),workspaceId:folder.id})).json().error,'git_required');
  } finally {clearTimeout(timeout);finish();await slow;await daemon.app.close();await rm(dir,{recursive:true,force:true});}
});


test('status shares identical checkout reads and refreshes after mutations or HEAD changes',async()=>{
  const {service,state,calls}=fixture();
  await Promise.all([service.status('/repo'),service.status('/same-checkout')]);
  const details=()=>calls.filter(c=>c.kind==='gh'&&c.args[0]==='pr').length;
  assert.equal(details(),1);
  await service.status('/repo');assert.equal(details(),1);
  await service.mutate('/repo',Command.parse({type:'github.push',...target}) as Extract<Command,{type:'github.push'}>);
  await service.status('/repo');assert.equal(details(),2);
  state.head=otherHead;await service.status('/repo');assert.equal(details(),3);
});
