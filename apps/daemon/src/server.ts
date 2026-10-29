import {validChannelCredential} from './channel-credentials.ts';
import {registerBrowserAutomation} from './browser-automation.ts';
import {detectSetup,setupPath,runSetup} from './worktree-setup.ts';
import {Agents} from './agents.ts';
import {Diagnostics} from './diagnostics.ts';
import Fastify from 'fastify';
import {z} from 'zod';
import {randomBytes,randomUUID,timingSafeEqual} from 'node:crypto';
import {mkdir,readFile,writeFile,chmod,stat,realpath} from 'node:fs/promises';
import {join,basename} from 'node:path';
import {Store,hash} from './store.ts';
import {Envelope,Fault,requireValue,daemonFeatures,projectDefaultProvider,type Workspace,type Project,type TerminalRecord,type Command,type PullRequestSource} from './contracts.ts';
import {Terminals,executable} from './terminals.ts';
import {SessionNames} from './session-names.ts';
import {ProviderUsageService} from './provider-usage.ts';
import * as work from './workspace.ts';
import {GitHub} from './github.ts';

export async function createDaemon(dataDir:string,github=new GitHub(),usage=new ProviderUsageService(),fetchDefault=work.fetchDefault){
  await mkdir(dataDir,{recursive:true,mode:0o700});await chmod(dataDir,0o700);
  const tokenPath=join(dataDir,'daemon-token');
  try{await writeFile(tokenPath,randomBytes(32).toString('hex'),{mode:0o600,flag:'wx'});}catch(e){if((e as NodeJS.ErrnoException).code!=='EEXIST')throw e;}
  await chmod(tokenPath,0o600);
  const token=(await readFile(tokenPath,'utf8')).trim(),store=new Store(join(dataDir,'developer.sqlite'));
  let controlEndpoint=`http://127.0.0.1:${process.env.NEURA_DEV_PORT??4318}`;
  const agents=new Agents(store,()=>controlEndpoint,tokenPath),terminals=new Terminals(store,undefined,agents,{endpoint:()=>controlEndpoint,tokenPath});
  const diagnostics=new Diagnostics(join(dataDir,'diagnostics'));
  diagnostics.record('daemon.start');
  const stopPerformanceMonitoring=diagnostics.startPerformanceMonitoring();
  const sessionNames=new SessionNames(store);
  const app=Fastify({logger:false,bodyLimit:2*1024*1024});
  app.addHook('onListen',async()=>{const address=app.server.address();if(address&&typeof address!=='string')controlEndpoint=`http://127.0.0.1:${address.port}`;});
  let queue:Promise<unknown>=Promise.resolve();
  let workspaceNetworkQueue:Promise<unknown>=Promise.resolve();
  let githubQueue:Promise<unknown>=Promise.resolve();
  app.addHook('onRequest',async(req,reply)=>{
    const supplied=Buffer.from((req.headers.authorization??'').replace(/^Bearer /,'')),expected=Buffer.from(token);
    if(req.headers.origin||supplied.length!==expected.length||!timingSafeEqual(supplied,expected))return reply.code(401).send({error:'unauthorized',message:'接続の認証に失敗しました。'});
    reply.header('Cache-Control','no-store');
  });
  app.setErrorHandler((error,req,reply)=>{const e=error instanceof Fault?error:error instanceof z.ZodError?new Fault('invalid_request','要求の形式が正しくありません。'):new Fault('operation_failed','操作に失敗しました。パスと接続状態を確認してください。',500);reply.code(e.status).send({error:e.code,message:e.message});});
  registerBrowserAutomation(app,store,token);
  const workspace=(id:string)=>requireValue(store.get<Workspace>('workspaces',z.uuid().parse(id)),'workspace_missing','作業フォルダが見つかりません。');
  const setupJobs=new Map<string,{controller:AbortController; promise:Promise<void>}>();
  for(const record of store.list<Workspace>('workspaces')){
    if(record.setup?.status==='running')store.put('workspaces',{...record,setup:{...record.setup,status:'failed',error:'Daemonが終了したためセットアップを中断しました。再実行してください。'}});
  }
  function startSetup(record:Workspace,project:Project,providers:Project['worktreeStartup']){
    const script=project.worktreeSetup!;
    const controller=new AbortController();
    const update=(setup:NonNullable<Workspace['setup']>)=>{const current=store.get<Workspace>('workspaces',record.id);if(current)store.put('workspaces',{...current,setup});};
    let output='';
    update({status:'running',script,output});
    const promise=runSetup(record.path,script,project.path,controller.signal,value=>{output=value;update({status:'running',script,output});})
      .then(async()=>{
        for(const provider of providers??[]){
          if(controller.signal.aborted)throw new Error('セットアップを中断しました。');
          try{await terminals.open(record,provider,false);}catch{output+=`\n${provider}の自動起動に失敗しました。タブから起動してください。`;}
        }
        update({status:'succeeded',script,output});
      }).catch(error=>update({status:'failed',script,output,error:error instanceof Error?error.message:'セットアップに失敗しました。'}))
      .finally(()=>setupJobs.delete(record.id));
    setupJobs.set(record.id,{controller,promise});
  }
  async function execute(c:Command,operationId:string,fetchedTarget?:(Awaited<ReturnType<typeof work.fetchDefault>> & {pullRequestSource?:Omit<PullRequestSource,'localBranch'>})):Promise<unknown>{
    if(c.type==='workspace.create'&&c.baseRef&&c.pullRequest)throw new Fault('invalid_source','作成元は一つだけ指定してください。');
    if(!fetchedTarget && ((c.type==='workspace.create'&&!c.baseRef)||c.type==='workspace.sync-default')){
      let root:string;
      if(c.type==='workspace.create'){
        const project=requireValue(store.get<Project>('projects',c.projectId),'project_missing','プロジェクトがありません。');
        if(project.isGit===false)throw new Fault('git_required','worktreeの作成にはGitリポジトリが必要です。');
        root=project.path;
      }else{
        const record=workspace(c.workspaceId);
        if(record.kind!=='root')throw new Fault('root_required','メインの作業フォルダで実行してください。');
        root=record.path;
      }
      const fetched=c.type==='workspace.create'&&c.pullRequest ? await github.fetchPullRequest(root,c.pullRequest) : await fetchDefault(root);
      // Only local mutation enters the interactive queue. Revalidate all state there:
      // a terminal may have opened or files may have changed during the fetch.
      const mutation=queue.catch(()=>{}).then(()=>execute(c,operationId,fetched));
      queue=mutation;
      return mutation;
    }
    switch(c.type){
      case 'project.remove':{
        requireValue(store.get<Project>('projects',c.projectId),'project_missing','プロジェクトがありません。');
        const workspaces=store.list<Workspace>('workspaces').filter(w=>w.projectId===c.projectId);
        if(workspaces.some(w=>setupJobs.has(w.id)))throw new Fault('setup_running','セットアップ完了後に削除してください。',409);
        // Stop owned processes before forgetting them; never remove folders or Git worktrees.
        for(const record of workspaces)await terminals.stopWorkspace(record.id);
        store.removeProject(c.projectId);
        return {ok:true};
      }
      case 'project.create':{
        const directory=join(dataDir,'projects',operationId);
        await mkdir(directory,{recursive:true,mode:0o700});
        const path=await realpath(directory);
        const project:Project={id:operationId,name:c.name,path,folderless:true,isGit:false,createdAt:new Date().toISOString()};
        store.putProjectWorkspace(project,{id:randomUUID(),projectId:project.id,name:'フリー',path,branch:'',kind:'scratch',createdAt:project.createdAt});
        return project;
      }
      case 'project.attach':{
        const project=requireValue(store.get<Project>('projects',c.projectId),'project_missing','プロジェクトがありません。');
        if(!project.folderless)throw new Fault('folder_already_attached','このプロジェクトにはすでにフォルダが紐づいています。',409);
        const {path,isGit}=await work.projectFolder(c.path);
        if(store.list<Project>('projects').some(p=>p.path===path))throw new Fault('project_exists','このフォルダはすでにプロジェクトに追加されています。',409);
        if(store.list<Workspace>('workspaces').some(w=>w.path===path))throw new Fault('workspace_exists','このフォルダはすでに作業領域として使用されています。',409);
        const branch=isGit?(await work.git(path,['branch','--show-current'])).trim()||'(detached)':'';
        const attached:Project={...project,path,isGit,folderless:false};
        // Keep scratch IDs and cwd stable, including resumable CLI sessions and browser storage.
        store.putProjectWorkspace(attached,{id:operationId,projectId:project.id,name:basename(path),path,branch,kind:isGit?'root':'folder',createdAt:new Date().toISOString()});
        return attached;
      }
      case 'project.add':{
        const {path,isGit}=await work.projectFolder(c.path),existing=store.list<Project>('projects').find(p=>p.path===path);
        if(store.list<Workspace>('workspaces').some(w=>w.kind==='scratch'&&w.path===path))throw new Fault('managed_folder','フリーの作業領域はフォルダとして追加できません。',409);
        const project:Project=existing?{...existing,isGit}:{id:operationId,name:basename(path),path,isGit,createdAt:new Date().toISOString()};
        const branch=isGit?(await work.git(path,['branch','--show-current'])).trim()||'(detached)':'';
        const root=existing?store.list<Workspace>('workspaces').find(w=>w.projectId===existing.id&&(w.kind==='root'||w.kind==='folder')):undefined;
        store.put('projects',project);store.put('workspaces',{id:root?.id??randomUUID(),projectId:project.id,name:root?.name??'メイン',path,branch,kind:isGit?'root':'folder',createdAt:root?.createdAt??project.createdAt} as Workspace);return project;
      }
      case 'project.set-worktree-startup':{
        const project=requireValue(store.get<Project>('projects',c.projectId),'project_missing','プロジェクトがありません。');
        const updated={...project,worktreeStartup:c.providers};
        store.put('projects',updated);return updated;
      }
      case 'project.set-default-providers':{
        const project=requireValue(store.get<Project>('projects',c.projectId),'project_missing','プロジェクトがありません。');
        const updated={...project,
          ...(c.defaultConversationProvider!==undefined?{defaultConversationProvider:c.defaultConversationProvider}:{}),
          ...(c.defaultDelegationProvider!==undefined?{defaultDelegationProvider:c.defaultDelegationProvider}:{})};
        store.put('projects',updated);return updated;
      }
      case 'project.set-worktree-setup':{
        const project=requireValue(store.get<Project>('projects',c.projectId),'project_missing','プロジェクトがありません。');
        if(project.isGit===false)throw new Fault('git_required','Gitリポジトリを選択してください。');
        if(c.script)await setupPath(project.path,c.script);
        const updated={...project,worktreeSetup:c.script||undefined};store.put('projects',updated);return updated;
      }
      case 'workspace.setup':{
        const record=workspace(c.workspaceId);
        if(record.kind!=='worktree')throw new Fault('worktree_required','worktreeを選択してください。');
        if(setupJobs.has(record.id))throw new Fault('setup_running','セットアップを実行中です。',409);
        if(store.list<TerminalRecord>('terminals').some(t=>t.workspaceId===record.id&&t.status==='running'))throw new Fault('workspace_running','ターミナルとエージェントを停止してから再実行してください。',409);
        const project=requireValue(store.get<Project>('projects',record.projectId),'project_missing','プロジェクトがありません。');
        if(!project.worktreeSetup)throw new Fault('setup_missing','プロジェクトでsetup scriptを設定してください。');
        startSetup(record,project,[]);return {ok:true};
      }
      case 'workspace.create':{
        const project=requireValue(store.get<Project>('projects',c.projectId),'project_missing','プロジェクトがありません。');
        if(project.isGit===false)throw new Fault('git_required','worktreeの作成にはGitリポジトリが必要です。通常のフォルダでは、そのまま作業を開始できます。');
        const commit=c.baseRef ? (await work.git(project.path,['rev-parse','--verify','--end-of-options',`${c.baseRef}^{commit}`])).trim() : fetchedTarget!.commit;
        const name=c.name??`worktree-${operationId.slice(0,8)}`;
        const slug=(c.name??'worktree').normalize('NFKC').replace(/[^\p{L}\p{N}]+/gu,'-').replace(/^-|-$/g,'').slice(0,40)||'work';
        const branch=`neura/${slug}-${operationId.slice(0,8)}`,path=join(dataDir,'worktrees',project.id,`${slug}-${operationId.slice(0,8)}`);await mkdir(join(dataDir,'worktrees',project.id),{recursive:true});
        await work.git(project.path,['worktree','add','-b',branch,path,commit]);
        const record:Workspace={id:operationId,projectId:project.id,name,nameSource:c.name?'manual':'session',path,branch,kind:'worktree',createdAt:new Date().toISOString(),...(fetchedTarget?.pullRequestSource?{pullRequestSource:{...fetchedTarget.pullRequestSource,localBranch:branch}}:{})};store.put('workspaces',record);
        // Worktree creation is successful even if an optional CLI cannot start.
        // The operation's cached response prevents retries from opening duplicates.
        const startupErrors:string[]=[];
        if(project.worktreeSetup){startSetup(record,project,c.skipStartup?[]:project.worktreeStartup);return {...record,setup:{status:'running',script:project.worktreeSetup,output:''},startupErrors};}
        for(const provider of c.skipStartup?[]:project.worktreeStartup??[]){
          try{await terminals.open(record,provider,false);}
          catch(error){startupErrors.push(error instanceof Fault?error.message:`${provider}の自動起動に失敗しました。タブから再度起動してください。`);}
        }
        return {...record,startupErrors};
      }
      case 'workspace.sync-default':{
        const record=workspace(c.workspaceId);
        if(record.kind!=='root')throw new Fault('root_required','メインの作業フォルダで実行してください。');
        if(store.list<TerminalRecord>('terminals').some(t=>t.workspaceId===record.id&&t.status==='running'))throw new Fault('workspace_running','メインで実行中のターミナルとエージェントを停止してください。',409);
        const target=await work.syncDefault(record.path,fetchedTarget);
        const updated={...record,branch:target.branch};store.put('workspaces',updated);return updated;
      }
      case 'workspace.delete':{
        const record=workspace(c.workspaceId);
        if(setupJobs.has(record.id))throw new Fault('setup_running','セットアップ完了後に削除してください。',409);
        if(record.kind!=='worktree')throw new Fault('worktree_required','削除できるのは追加したworktreeだけです。');
        if(!c.stopTerminals&&store.list<TerminalRecord>('terminals').some(t=>t.workspaceId===record.id&&t.status==='running'))throw new Fault('workspace_running','このworktreeのターミナルとエージェントを停止してから削除してください。',409);
        const project=requireValue(store.get<Project>('projects',record.projectId),'project_missing','プロジェクトがありません。');
        const checkChanges=async()=>{
          if(c.cleanup){
            workspace(c.cleanup.callerWorkspaceId);
            if(c.cleanup.callerWorkspaceId===record.id)throw new Fault('workspace_self_cleanup','現在作業中のworktreeは自分自身から削除できません。',409);
            if(c.discardChanges||!c.stopTerminals)throw new Fault('workspace_cleanup_options','cleanupでは変更破棄は禁止で、停止確認が必要です。',409);
            const active=agents.list().filter(a=>a.workspaceId===record.id);
            const unverifiedTerminal=store.list<TerminalRecord>('terminals').some(t=>t.workspaceId===record.id&&t.status==='running'&&(t.provider==='codex'?!active.some(a=>a.terminalId===t.id):t.activity!=='idle'));
            if(unverifiedTerminal)throw new Fault('workspace_task_unfinished','作業終了を確認できないターミナルがあります。確認して停止するまで保持します。',409);
            if(active.some(a=>a.turnId||a.status==='working'||a.status==='waiting'||a.status==='failed'||a.pending.length||(a.reports?.length??0)||(a.watching?.length??0)))throw new Fault('workspace_task_unfinished','未完了・未実行指示・未受領報告・監視のある作業は削除できません。',409);
            const head=(await work.git(record.path,['rev-parse','HEAD'])).trim();
            if(head!==c.cleanup.expectedHead)throw new Fault('workspace_head_changed','HEADが変わりました。削除せず作業内容を再確認してください。',409);
            await github.verifyCleanup(record.path,c.cleanup.mergedPR,head);
          }
          if(c.discardChanges)return;
          // Git removes ignored files even without --force, including local secrets.
          const ignored=await work.git(record.path,['ls-files','--others','--ignored','--exclude-standard','--directory','-z']);
          if(ignored.length)throw new Fault('workspace_ignored_files','Gitの無視対象ファイル・フォルダがあります（.envなど）。必要なデータを退避するか、削除確認で「変更・未追跡ファイルも含めて削除」を選んでください。',409);
          const changes=await work.git(record.path,['status','--porcelain=v1','-z','--untracked-files=normal']);
          if(changes.length)throw new Fault('workspace_dirty','未コミットの変更または未追跡ファイルがあります。必要なデータを退避するか、削除確認で「変更・未追跡ファイルも含めて削除」を選んでください。',409);
          if(c.cleanup&&(await work.git(record.path,['rev-parse','HEAD'])).trim()!==c.cleanup.expectedHead)throw new Fault('workspace_head_changed','HEADが変わりました。作業を保持しました。',409);
        };
        await checkChanges();
        if(c.stopTerminals){await terminals.stopWorkspace(record.id);await checkChanges();}
        // A single --force permits explicitly approved data loss, but still refuses
        // locked worktrees. Keep the branch so committed work remains recoverable.
        await work.git(project.path,['worktree','remove',...(c.discardChanges?['--force']:[]),'--',record.path]);
        store.deleteWorkspace(record.id);
        return {ok:true};
      }
      case 'terminal.open':{
        if(setupJobs.has(c.workspaceId))throw new Fault('setup_running','セットアップ完了後に起動してください。',409);
        const record=workspace(c.workspaceId),previous=c.resumeId?agents.get(c.resumeId):undefined;
        const provider=c.provider??(previous?(previous.provider??'codex'):projectDefaultProvider(store.get<Project>('projects',record.projectId),'conversation'));
        return terminals.open(record,provider,c.resume,{prompt:c.prompt,resumeId:c.resumeId,parentTaskId:c.parentTaskId});
      }
      case 'agent.report':return agents.report(c.agentId,c.text,c.sourceTerminalId);
      case 'agent.ack':return agents.ack(c.agentId,c.reportIds);
      case 'agent.watch':return agents.watch(c.agentId,c.taskIds);
      case 'agent.send':return agents.send(c.agentId,c.text,c.mode,c.expectedTurnId);
      case 'agent.interrupt':return agents.interrupt(c.agentId,c.expectedTurnId);
      case 'agent.respond':return agents.respond(c.agentId,c.requestId,c.result);
      case 'terminal.input':return terminals.input(c.terminalId,c.clientId,c.data);
      case 'terminal.resize':return terminals.resize(c.terminalId,c.clientId,c.cols,c.rows);
      case 'terminal.stop':return terminals.stop(c.terminalId);
      case 'file.save':return work.saveFile(fileWorkspace(c.workspaceId).path,c.path,c.content,c.expectedHash);
      case 'github.push':case 'github.create':case 'github.merge':{const w=gitWorkspace(c.workspaceId);return github.mutate(w.path,c,w.pullRequestSource);}
    }
  }
  let folderRefresh:Promise<void>|undefined;
  function refreshFolderProjects(){
    // State polling discovers git init without reopening the folder or replacing its IDs.
    // Share concurrent probes, and do not put filesystem/Git reads on the PTY command queue.
    folderRefresh??=Promise.all(store.list<Project>('projects').filter(p=>p.isGit===false&&!p.folderless).map(async candidate=>{
      try {
        const marker=await stat(join(candidate.path,'.git'));
        if(!marker.isDirectory()&&!marker.isFile())return;
        const root=(await work.git(candidate.path,['rev-parse','--show-toplevel'],2000)).trim();
        if(await realpath(root)!==await realpath(candidate.path))return;
        const branch=(await work.git(candidate.path,['branch','--show-current'],2000)).trim()||'(detached)';
        // Re-read after async probes: project.add may already have upgraded this project.
        const project=store.get<Project>('projects',candidate.id);
        if(!project||project.isGit!==false||project.path!==candidate.path)return;
        const workspace=store.list<Workspace>('workspaces').find(w=>w.projectId===project.id&&w.kind==='folder'&&w.path===project.path);
        if(!workspace)return;
        store.put('projects',{...project,isGit:true});
        store.put('workspaces',{...workspace,kind:'root',branch});
      } catch {
        // Missing/offline folders and an incomplete git init must not break state polling.
      }
    })).then(()=>{}).finally(()=>{folderRefresh=undefined;});
    return folderRefresh;
  }
  app.get('/v1/state',async()=>{await refreshFolderProjects();void sessionNames.refresh().catch(()=>{});return {...store.state(),features:daemonFeatures};});
  app.get('/v1/workspaces/:id/checks',async req=>{const w=workspace((req.params as {id:string}).id);return (w.kind==='folder'||w.kind==='scratch')?{state:'unsupported',checks:[],fetchedAt:new Date().toISOString()}:github.checks(w.path);});
  app.get('/v1/projects/:id/setup-scripts',async req=>{const project=requireValue(store.get<Project>('projects',z.uuid().parse((req.params as {id:string}).id)),'project_missing','プロジェクトがありません。');return {scripts:await detectSetup(project.path)};});
  app.get('/v1/projects/:id/pull-requests',async req=>{
    const project=requireValue(store.get<Project>('projects',z.uuid().parse((req.params as {id:string}).id)),'project_missing','プロジェクトがありません。');
    if(project.isGit===false)throw new Fault('git_required','Gitリポジトリを選択してください。');
    const query=z.string().trim().max(500).default('').parse((req.query as Record<string,string>).query);
    return github.pullRequests(project.path,query);
  });
  app.get('/v1/usage',async()=>({providers:await usage.read()}));
  app.addHook('onClose',async()=>{await usage.close();});
  app.get('/v1/capabilities',async()=>({protocolVersion:1,features:daemonFeatures,providers:await Promise.all(['codex','claude'].map(async provider=>({provider,available:await executable(provider as 'codex'|'claude').then(()=>true,()=>false)}))),remoteAccess:false}));
  app.get('/v1/notifications',async req=>{const after=z.coerce.number().int().min(0).default(0).parse((req.query as Record<string,string>).after);return store.notifications(after);});
  app.get('/v1/events',async req=>{const after=z.coerce.number().int().min(0).default(0).parse((req.query as Record<string,string>).after);return {events:store.db.prepare('SELECT * FROM events WHERE sequence>? ORDER BY sequence LIMIT 256').all(after)};});
  app.post('/v1/commands',async req=>{
    const {operationId,command}=Envelope.parse(req.body),digest=hash(JSON.stringify(command));
    const started=performance.now(),traced=!['terminal.input','terminal.resize'].includes(command.type);
    if(traced)diagnostics.record('operation.received',command.type,operationId);
    // Network operations must not block PTY input/resize or local file saves.
    const isGitHub=command.type.startsWith('github.');
    const isRemoteWorkspace=command.type==='workspace.sync-default'||(command.type==='workspace.create'&&!command.baseRef);
    // Deletion is a barrier: finish GitHub mutations before removing their cwd.
    const isDelete=command.type==='workspace.delete'||command.type==='project.remove';
    const preceding=isDelete?Promise.allSettled([queue,githubQueue]):isGitHub?githubQueue:isRemoteWorkspace?workspaceNetworkQueue:queue;
    const result=preceding.catch(()=>{}).then(async()=>{
      if(traced)diagnostics.record('operation.executing',command.type,operationId,performance.now()-started);
      const existing=store.db.prepare('SELECT * FROM operations WHERE id=?').get(operationId);
      if(existing){
        if(existing.hash!==digest)throw new Fault('operation_conflict','同じ操作IDに別の内容が指定されています。',409);
        if(existing.status==='pending')throw new Fault('operation_unknown','前回の操作結果を確認できません。状態を更新してから確認してください。',409);
        const result=JSON.parse(existing.result as string);if(existing.status==='failed')throw new Fault(result.code,result.message,result.status);return result;
      }
      // Terminal input is never automatically replayed after an uncertain response.
      store.db.prepare('INSERT INTO operations(id,hash,status) VALUES(?,?,?)').run(operationId,digest,'pending');
      try{const value=await execute(command,operationId);store.db.prepare('UPDATE operations SET status=?,result=? WHERE id=?').run('done',JSON.stringify(value),operationId);return value;}
      catch(e){const fault=e instanceof Fault?e:new Fault('operation_failed','操作に失敗しました。パスと接続状態を確認してください。',500);store.db.prepare('UPDATE operations SET status=?,result=? WHERE id=?').run('failed',JSON.stringify({code:fault.code,message:fault.message,status:fault.status}),operationId);throw fault;}
    });if(isDelete){queue=result;githubQueue=result;}else if(isGitHub)githubQueue=result;else if(isRemoteWorkspace)workspaceNetworkQueue=result;else queue=result;
    try {const value=await result;if(traced)diagnostics.record('operation.success',command.type,operationId,performance.now()-started);return value;}
    catch(error){diagnostics.record('operation.failure',command.type,operationId,performance.now()-started);throw error;}
  });
  app.post('/v1/claude/:terminalId/channel',async req=>{
    const terminalId=z.uuid().parse((req.params as {terminalId:string}).terminalId);
    if(!await validChannelCredential(tokenPath,terminalId,req.headers['x-neura-channel-token']))throw new Fault('channel_forbidden','このターミナルのChannels認証が必要です。',403);
    return agents.channel(terminalId);
  });
  app.post('/v1/claude/:terminalId/channel-ack',async req=>{
    const terminalId=z.uuid().parse((req.params as {terminalId:string}).terminalId);
    if(!await validChannelCredential(tokenPath,terminalId,req.headers['x-neura-channel-token']))throw new Fault('channel_forbidden','このターミナルのChannels認証が必要です。',403);
    return agents.acknowledgeChannel(terminalId,z.object({nonce:z.uuid()}).parse(req.body).nonce);
  });
  app.get('/v1/agents',async()=>({agents:agents.list(),currentSessionIds:Object.fromEntries(store.list<TerminalRecord>('terminals').filter(t=>t.provider==='claude'&&t.sessionId).map(t=>[t.id,t.sessionId])),revision:store.state().revision}));
  app.get('/v1/agents/:id',async req=>agents.read(z.uuid().parse((req.params as {id:string}).id),z.string().max(4096).optional().parse((req.query as {cursor?:string}).cursor)));
  app.get('/v1/terminals/:id/output',async req=>{
    const id=z.uuid().parse((req.params as {id:string}).id),after=z.coerce.number().int().min(0).default(0).parse((req.query as Record<string,string>).after);
    const record=requireValue(store.get<TerminalRecord>('terminals',id),'terminal_missing','ターミナルがありません。');return {...store.output(id,after),status:record.status,cols:record.cols,rows:record.rows};
  });
  app.get('/v1/workspaces/:id/files',async req=>work.files(fileWorkspace((req.params as {id:string}).id).path,z.string().max(4096).default('').parse((req.query as Record<string,string>).path)));
  app.get('/v1/workspaces/:id/file',async req=>work.file(fileWorkspace((req.params as {id:string}).id).path,z.string().min(1).max(4096).parse((req.query as Record<string,string>).path)));
  const fileWorkspace=(id:string)=>{const value=workspace(id);if(value.kind==='scratch')throw new Fault('folder_required','ファイルを操作するにはフォルダを紐づけてください。');return value;};
  const gitWorkspace=(id:string)=>{const value=workspace(id);if(value.kind==='folder'||value.kind==='scratch')throw new Fault('git_required','このフォルダではGitを使用していません。');return value;};
  app.get('/v1/workspaces/:id/git',async req=>work.gitStatus(gitWorkspace((req.params as {id:string}).id).path));
  app.get('/v1/workspaces/:id/github',async req=>{const w=gitWorkspace((req.params as {id:string}).id);return github.status(w.path,(req.query as {refresh?:string}).refresh==='true',w.pullRequestSource);});
  app.get('/v1/workspaces/:id/diff',async req=>work.diff(gitWorkspace((req.params as {id:string}).id).path,z.string().min(1).max(4096).parse((req.query as Record<string,string>).path)));
  app.addHook('onClose',async()=>{stopPerformanceMonitoring();await Promise.allSettled([queue,githubQueue,workspaceNetworkQueue]);for(const job of setupJobs.values())job.controller.abort();await Promise.all([...setupJobs.values()].map(job=>job.promise));await folderRefresh;await sessionNames.close();await terminals.shutdown();store.close();diagnostics.record('daemon.end');await diagnostics.flush();});
  return {app,store,token};
}
