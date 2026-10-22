import Fastify from 'fastify';
import {z} from 'zod';
import {randomBytes,randomUUID,timingSafeEqual} from 'node:crypto';
import {mkdir,readFile,writeFile,chmod} from 'node:fs/promises';
import {join,basename} from 'node:path';
import {Store,hash} from './store.ts';
import {Envelope,Fault,requireValue,type Workspace,type Project,type TerminalRecord,type Command} from './contracts.ts';
import {Terminals,executable} from './terminals.ts';
import {SessionNames} from './session-names.ts';
import * as work from './workspace.ts';
import {GitHub} from './github.ts';

export async function createDaemon(dataDir:string,github=new GitHub()){
  await mkdir(dataDir,{recursive:true,mode:0o700});await chmod(dataDir,0o700);
  const tokenPath=join(dataDir,'daemon-token');
  try{await writeFile(tokenPath,randomBytes(32).toString('hex'),{mode:0o600,flag:'wx'});}catch(e){if((e as NodeJS.ErrnoException).code!=='EEXIST')throw e;}
  await chmod(tokenPath,0o600);
  const token=(await readFile(tokenPath,'utf8')).trim(),store=new Store(join(dataDir,'developer.sqlite')),terminals=new Terminals(store);
  const sessionNames=new SessionNames(store);
  const app=Fastify({logger:false,bodyLimit:2*1024*1024});
  let queue:Promise<unknown>=Promise.resolve();
  let githubQueue:Promise<unknown>=Promise.resolve();
  app.addHook('onRequest',async(req,reply)=>{
    const supplied=Buffer.from((req.headers.authorization??'').replace(/^Bearer /,'')),expected=Buffer.from(token);
    if(req.headers.origin||supplied.length!==expected.length||!timingSafeEqual(supplied,expected))return reply.code(401).send({error:'unauthorized',message:'接続の認証に失敗しました。'});
    reply.header('Cache-Control','no-store');
  });
  app.setErrorHandler((error,req,reply)=>{const e=error instanceof Fault?error:error instanceof z.ZodError?new Fault('invalid_request','要求の形式が正しくありません。'):new Fault('operation_failed','操作に失敗しました。パスと接続状態を確認してください。',500);reply.code(e.status).send({error:e.code,message:e.message});});
  const workspace=(id:string)=>requireValue(store.get<Workspace>('workspaces',z.uuid().parse(id)),'workspace_missing','作業フォルダが見つかりません。');
  async function execute(c:Command,operationId:string):Promise<unknown>{
    switch(c.type){
      case 'project.add':{
        const {path,isGit}=await work.projectFolder(c.path),existing=store.list<Project>('projects').find(p=>p.path===path);
        const project:Project=existing?{...existing,isGit}:{id:operationId,name:basename(path),path,isGit,createdAt:new Date().toISOString()};
        const branch=isGit?(await work.git(path,['branch','--show-current'])).trim()||'(detached)':'';
        const root=existing?store.list<Workspace>('workspaces').find(w=>w.projectId===existing.id&&w.kind!=='worktree'):undefined;
        store.put('projects',project);store.put('workspaces',{id:root?.id??randomUUID(),projectId:project.id,name:root?.name??'メイン',path,branch,kind:isGit?'root':'folder',createdAt:root?.createdAt??project.createdAt} as Workspace);return project;
      }
      case 'workspace.create':{
        const project=requireValue(store.get<Project>('projects',c.projectId),'project_missing','プロジェクトがありません。');
        if(project.isGit===false)throw new Fault('git_required','worktreeの作成にはGitリポジトリが必要です。通常のフォルダでは、そのまま作業を開始できます。');
        const commit=(await work.git(project.path,['rev-parse','--verify','--end-of-options',`${c.baseRef}^{commit}`])).trim();
        const name=c.name??`worktree-${operationId.slice(0,8)}`;
        const slug=(c.name??'worktree').normalize('NFKC').replace(/[^\p{L}\p{N}]+/gu,'-').replace(/^-|-$/g,'').slice(0,40)||'work';
        const branch=`neura/${slug}-${operationId.slice(0,8)}`,path=join(dataDir,'worktrees',project.id,`${slug}-${operationId.slice(0,8)}`);await mkdir(join(dataDir,'worktrees',project.id),{recursive:true});
        await work.git(project.path,['worktree','add','-b',branch,path,commit]);
        const record:Workspace={id:operationId,projectId:project.id,name,path,branch,kind:'worktree',createdAt:new Date().toISOString()};store.put('workspaces',record);return record;
      }
      case 'terminal.open':return terminals.open(workspace(c.workspaceId),c.provider,c.resume);
      case 'terminal.input':return terminals.input(c.terminalId,c.clientId,c.data);
      case 'terminal.resize':return terminals.resize(c.terminalId,c.clientId,c.cols,c.rows);
      case 'terminal.stop':return terminals.stop(c.terminalId);
      case 'file.save':return work.saveFile(workspace(c.workspaceId).path,c.path,c.content,c.expectedHash);
      case 'github.push':case 'github.create':case 'github.merge':return github.mutate(gitWorkspace(c.workspaceId).path,c);
    }
  }
  app.get('/v1/state',async()=>{await sessionNames.refresh();return store.state();});
  app.get('/v1/capabilities',async()=>({protocolVersion:1,providers:await Promise.all(['codex','claude'].map(async provider=>({provider,available:await executable(provider as 'codex'|'claude').then(()=>true,()=>false)}))),remoteAccess:false}));
  app.get('/v1/events',async req=>{const after=z.coerce.number().int().min(0).default(0).parse((req.query as Record<string,string>).after);return {events:store.db.prepare('SELECT * FROM events WHERE sequence>? ORDER BY sequence LIMIT 256').all(after)};});
  app.post('/v1/commands',async req=>{
    const {operationId,command}=Envelope.parse(req.body),digest=hash(JSON.stringify(command));
    // Network operations must not block PTY input/resize or local file saves.
    const isGitHub=command.type.startsWith('github.');
    const result=(isGitHub?githubQueue:queue).catch(()=>{}).then(async()=>{
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
    });if(isGitHub)githubQueue=result;else queue=result;return result;
  });
  app.get('/v1/terminals/:id/output',async req=>{
    const id=z.uuid().parse((req.params as {id:string}).id),after=z.coerce.number().int().min(0).default(0).parse((req.query as Record<string,string>).after);
    const record=requireValue(store.get<TerminalRecord>('terminals',id),'terminal_missing','ターミナルがありません。');return {...store.output(id,after),status:record.status,cols:record.cols,rows:record.rows};
  });
  app.get('/v1/workspaces/:id/files',async req=>work.files(workspace((req.params as {id:string}).id).path,z.string().max(4096).default('').parse((req.query as Record<string,string>).path)));
  app.get('/v1/workspaces/:id/file',async req=>work.file(workspace((req.params as {id:string}).id).path,z.string().min(1).max(4096).parse((req.query as Record<string,string>).path)));
  const gitWorkspace=(id:string)=>{const value=workspace(id);if(value.kind==='folder')throw new Fault('git_required','このフォルダではGitを使用していません。');return value;};
  app.get('/v1/workspaces/:id/git',async req=>work.gitStatus(gitWorkspace((req.params as {id:string}).id).path));
  app.get('/v1/workspaces/:id/github',async req=>github.status(gitWorkspace((req.params as {id:string}).id).path));
  app.get('/v1/workspaces/:id/diff',async req=>work.diff(gitWorkspace((req.params as {id:string}).id).path,z.string().min(1).max(4096).parse((req.query as Record<string,string>).path)));
  app.addHook('onClose',async()=>{await Promise.allSettled([queue,githubQueue]);await sessionNames.close();await terminals.shutdown();store.close();});
  return {app,store,token};
}
