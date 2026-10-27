import {randomUUID} from 'node:crypto';
import {GitHubRefreshCache} from './github-refresh.ts';
import {execFile} from 'node:child_process';
import {access,realpath} from 'node:fs/promises';
import {constants} from 'node:fs';
import {homedir} from 'node:os';
import {join,delimiter} from 'node:path';
import {z} from 'zod';
import {Fault,type Command,type PullRequestSource} from './contracts.ts';
import {git} from './workspace.ts';
import {ChecksCache,parseChecks,type CISnapshot} from './github-checks.ts';

type Runner=(cwd:string,args:string[])=>Promise<string>;
type Mutation=Extract<Command,{type:'github.push'|'github.create'|'github.merge'}>;
const repoName=z.string().regex(/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/);
const repositorySchema=z.object({full_name:repoName,default_branch:z.string(),allow_merge_commit:z.boolean(),allow_squash_merge:z.boolean(),allow_rebase_merge:z.boolean()});
const pullSchema=z.object({number:z.number(),state:z.string(),head:z.object({ref:z.string(),repo:z.object({full_name:z.string()}).nullable()})});
const checkSchema=z.object({name:z.string().optional(),context:z.string().optional(),status:z.string().optional(),conclusion:z.string().nullable().optional(),state:z.string().optional(),detailsUrl:z.string().optional(),targetUrl:z.string().optional()});
const detailSchema=z.object({number:z.number(),title:z.string(),body:z.string(),url:z.string(),state:z.string(),isDraft:z.boolean(),headRefName:z.string(),headRefOid:z.string(),baseRefName:z.string(),mergeStateStatus:z.string(),reviewDecision:z.string().nullable(),headRepository:z.object({name:z.string()}).nullable(),headRepositoryOwner:z.object({login:z.string()}).nullable(),statusCheckRollup:z.array(checkSchema).nullable(),author:z.object({login:z.string()}).nullable().optional(),additions:z.number().optional(),deletions:z.number().optional(),changedFiles:z.number().optional(),files:z.array(z.object({path:z.string(),additions:z.number(),deletions:z.number()})).optional()});
const commentSchema=z.object({id:z.number(),body:z.string().nullable().optional(),user:z.object({login:z.string()}).nullable(),html_url:z.string(),created_at:z.string().optional(),submitted_at:z.string().nullable().optional(),path:z.string().optional(),line:z.number().nullable().optional(),original_line:z.number().nullable().optional(),state:z.string().optional()});
const threadsSchema=z.array(z.object({data:z.object({repository:z.object({pullRequest:z.object({reviewThreads:z.object({nodes:z.array(z.object({isResolved:z.boolean()}))})})})})}));

export function githubRepository(remote:string){
  const match=remote.trim().match(/^(?:https:\/\/github\.com\/|git@github\.com:|ssh:\/\/git@github\.com\/)([A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+?)\/?$/);
  if(!match)throw new Fault('github_remote','origin に github.com の HTTPS または SSH リポジトリを設定してください。');
  return repoName.parse(match[1].replace(/\.git$/,''));
}
async function ghExecutable(){
  const paths=[join(homedir(),'.local/bin/gh'),...['/opt/homebrew/bin','/usr/local/bin',...(process.env.PATH??'').split(delimiter)].map(dir=>join(dir,'gh'))];
  for(const path of paths)try{await access(path,constants.X_OK);return await realpath(path);}catch{}
  throw new Fault('github_cli_missing','GitHub CLI がありません。brew install gh を実行し、ターミナルで gh auth login を完了してください。');
}
export const runGitHub:Runner=async(cwd,args)=>{
  const executable=await ghExecutable();
  return new Promise((resolve,reject)=>{
    execFile(executable,args,{cwd,timeout:60000,maxBuffer:16*1024*1024,env:{...process.env,GH_HOST:'github.com',GH_PROMPT_DISABLED:'1',GH_PAGER:'cat',GH_DEBUG:'',NO_COLOR:'1'}},(error,stdout,stderr)=>{
      if(!error){resolve(stdout);return;}
      // Do not return API payloads or credential/debug output to the UI or operation journal.
      const message=stderr.toLowerCase();
      if(/auth login|not logged|bad credentials|http 401/.test(message))reject(new Fault('github_auth','GitHub にログインできません。ターミナルで gh auth login --hostname github.com を実行してください。'));
      else if(/http 403|http 429|rate limit/.test(message))reject(new Fault('github_forbidden','GitHub の権限または API 利用制限により操作できません。権限を確認し、時間を置いて更新してください。'));
      else if(/http 404/.test(message))reject(new Fault('github_missing','リポジトリまたは PR が見つかりません。GitHub のログイン先とアクセス権を確認してください。'));
      else if(/http 405|http 409|http 422/.test(message))reject(new Fault('github_rejected','GitHub が操作を受け付けませんでした。ブランチ・PR・保護ルールを更新して確認してください。',409));
      else reject(new Fault('github_failed','GitHub の操作を完了できませんでした。接続を確認して更新してください。作成・マージの結果が不明な場合は GitHub 上で確認してください。',502));
    });
  });
};

const sourcePullSchema=z.object({number:z.number().int().positive(),title:z.string(),state:z.enum(['OPEN','CLOSED','MERGED']),headRefName:z.string()});
const sourceFields='number,title,state,headRefName';
export function pullRequestNumber(input:string,repository:string){
  const text=input.trim();
  if(/^#?[1-9]\d*$/.test(text)){
    const value=Number(text.replace(/^#/,''));
    if(Number.isSafeInteger(value))return value;
  }
  const match=text.match(/^https:\/\/github\.com\/([A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+)\/pull\/([1-9]\d*)(?:[/?#].*)?$/);
  if(match){
    if(match[1].toLowerCase()!==repository.toLowerCase())throw new Fault('pr_repository_mismatch','選択したプロジェクトとPRのリポジトリが異なります。プロジェクトを選び直してください。');
    const value=Number(match[2]);if(Number.isSafeInteger(value))return value;
  }
  throw new Fault('invalid_pr','PR番号（例: #123）またはGitHubのPR URLを入力してください。');
}

export class GitHub {
  private checksCache=new ChecksCache();
  private statusCache=new GitHubRefreshCache<Awaited<ReturnType<GitHub['fetchStatus']>>>(()=>60000);
  constructor(private run:Runner=runGitHub,private gitRun:Runner=git){}
  async pullRequests(root:string,query=''){
    const repository=githubRepository(await this.gitRun(root,['remote','get-url','origin']));
    if(/^#?\d+$/.test(query)||/^https?:\/\//i.test(query)){
      const number=pullRequestNumber(query,repository);
      return {pullRequests:[sourcePullSchema.parse(JSON.parse(await this.run(root,['pr','view',String(number),'--repo',`github.com/${repository}`,'--json',sourceFields])))]};
    }
    const args=['pr','list','--repo',`github.com/${repository}`,'--state','all','--limit','50','--json',sourceFields];
    if(query)args.push('--search',query);
    return {pullRequests:z.array(sourcePullSchema).parse(JSON.parse(await this.run(root,args)))};
  }
  async fetchPullRequest(root:string,input:string){
    const repository=githubRepository(await this.gitRun(root,['remote','get-url','origin']));
    const number=pullRequestNumber(input,repository);
    // Validate access/existence for all PR states; never check out the user's main folder.
    sourcePullSchema.parse(JSON.parse(await this.run(root,['pr','view',String(number),'--repo',`github.com/${repository}`,'--json',sourceFields])));
    const ref=`refs/neura/pr-fetch/${randomUUID()}`;
    try {
      await this.gitRun(root,['fetch','--no-tags','origin',`+refs/pull/${number}/head:${ref}`]);
      const commit=(await this.gitRun(root,['rev-parse','--verify',`${ref}^{commit}`])).trim();
      return {branch:`PR #${number}`,commit,pullRequestSource:{repository,number,sourceHead:commit}};
    } finally {await this.gitRun(root,['update-ref','-d',ref]).catch(()=>{});}
  }
  private async api(root:string,endpoint:string,args:string[]=[]){return JSON.parse(await this.run(root,['api','--hostname','github.com',endpoint,...args])) as unknown;}
  private async pages(root:string,endpoint:string){return z.array(z.array(z.unknown())).parse(await this.api(root,endpoint,['--paginate','--slurp'])).flat();}
  private async commitContext(root:string){
    const repository=githubRepository(await this.gitRun(root,['remote','get-url','origin']));
    const head=(await this.gitRun(root,['rev-parse','--verify','HEAD'])).trim();
    return {repository,head};
  }
  private async context(root:string){
    const context=await this.commitContext(root);
    const branch=(await this.gitRun(root,['branch','--show-current'])).trim();
    if(!branch)throw new Fault('github_detached','ブランチをチェックアウトしてから GitHub を利用してください。');
    return {...context,branch};
  }
  private async repository(root:string,repository:string){return repositorySchema.parse(await this.api(root,`repos/${repository}`));}
  private async pulls(root:string,context:Awaited<ReturnType<GitHub['context']>>){
    const query=new URLSearchParams({state:'all',head:`${context.repository.split('/')[0]}:${context.branch}`,sort:'created',direction:'desc',per_page:'100'});
    return z.array(pullSchema).parse(await this.pages(root,`repos/${context.repository}/pulls?${query}`)).filter(pr=>pr.head.ref===context.branch&&pr.head.repo?.full_name.toLowerCase()===context.repository.toLowerCase());
  }
  private async detail(root:string,repository:string,number:number){
    return detailSchema.parse(JSON.parse(await this.run(root,['pr','view',String(number),'--repo',`github.com/${repository}`,'--json','number,title,body,url,state,isDraft,headRefName,headRefOid,baseRefName,mergeStateStatus,reviewDecision,headRepository,headRepositoryOwner,statusCheckRollup,author,additions,deletions,changedFiles,files'])));
  }
  private async unresolved(root:string,repository:string,number:number){
    const [owner,name]=repository.split('/');
    const query='query($owner:String!,$name:String!,$number:Int!,$endCursor:String){repository(owner:$owner,name:$name){pullRequest(number:$number){reviewThreads(first:100,after:$endCursor){nodes{isResolved} pageInfo{hasNextPage endCursor}}}}}';
    const result=threadsSchema.parse(await this.api(root,'graphql',['--paginate','--slurp','-f',`query=${query}`,'-f',`owner=${owner}`,'-f',`name=${name}`,'-F',`number=${number}`]));
    return result.flatMap(page=>page.data.repository.pullRequest.reviewThreads.nodes).filter(thread=>!thread.isResolved).length;
  }
  async checks(root:string):Promise<CISnapshot>{
    let context:Awaited<ReturnType<GitHub['commitContext']>>;
    try{context=await this.commitContext(root);}
    catch(error){return {state:error instanceof Fault&&error.code==='github_remote'?'unsupported':'unavailable',checks:[],fetchedAt:new Date().toISOString(),message:error instanceof Fault?error.message:'Git の状態を取得できません。'};}
    const {repository,head}=context;
    const result=await this.checksCache.read(`${repository}:${head}`,async()=>{
      const [owner,name]=repository.split('/');
      const query='query($owner:String!,$name:String!,$head:String!,$endCursor:String){repository(owner:$owner,name:$name){object(expression:$head){... on Commit{oid statusCheckRollup{contexts(first:100,after:$endCursor){nodes{... on CheckRun{name status conclusion detailsUrl} ... on StatusContext{context state targetUrl}} pageInfo{hasNextPage endCursor}}}}}}}';
      const value=await this.api(root,'graphql',['--paginate','--slurp','-f',`query=${query}`,'-f',`owner=${owner}`,'-f',`name=${name}`,'-f',`head=${head}`]);
      return {...parseChecks(value,head),repository,head,fetchedAt:new Date().toISOString()};
    });
    // A checkout/commit during the network request invalidates that result.
    try{const current=await this.commitContext(root);if(current.repository!==repository||current.head!==head)return {state:'unknown',checks:[],fetchedAt:new Date().toISOString(),message:'コミットが変わりました。次の更新でCIを確認します。'};}
    catch{return {state:'unavailable',checks:[],fetchedAt:new Date().toISOString()};}
    return result;
  }
  private async source(root:string,context:Awaited<ReturnType<GitHub['context']>>,source?:PullRequestSource){
    const parsed=z.object({repository:repoName,number:z.number().int().positive().safe(),localBranch:z.string().min(1),sourceHead:z.string().regex(/^[a-f0-9]{40,64}$/)}).safeParse(source);
    if(!parsed.success)return undefined;
    const value=parsed.data;
    if(value.repository.toLowerCase()!==context.repository.toLowerCase()||value.localBranch!==context.branch)return undefined;
    // Commits made on this worktree retain its explicit identity. An unrelated reset does not.
    try{await this.gitRun(root,['merge-base','--is-ancestor',value.sourceHead,context.head]);}catch{return undefined;}
    return value;
  }
  async status(root:string,force=false,source?:PullRequestSource){
    const context=await this.context(root);
    const binding=await this.source(root,context,source);
    const key=JSON.stringify([context.repository,context.branch,context.head,binding??null]);
    const result=await this.statusCache.read(key,()=>this.fetchStatus(root,context,binding),force);
    const current=await this.context(root);
    if(JSON.stringify(current)!==JSON.stringify(context))throw new Fault('github_stale','ブランチまたはコミットが変更されました。更新してください。',409);
    return result;
  }
  private async fetchStatus(root:string,context:Awaited<ReturnType<GitHub['context']>>,source?:PullRequestSource){
    const [repo,pulls]=await Promise.all([this.repository(root,context.repository),source?Promise.resolve([]):this.pulls(root,context)]);
    const selected=source??pulls.find(pr=>pr.state==='open')??pulls[0];
    const result={...context,sourcePullRequest:source?{repository:source.repository,number:source.number}:null,defaultBranch:repo.default_branch,mergeMethods:[...(repo.allow_squash_merge?['squash']:[]),...(repo.allow_merge_commit?['merge']:[]),...(repo.allow_rebase_merge?['rebase']:[])],fetchedAt:new Date().toISOString()};
    if(!selected)return {...result,pullRequest:null};
    const endpoint=`repos/${context.repository}`;
    const [pr,issueComments,reviews,lineComments,unresolvedThreads]=await Promise.all([
      this.detail(root,context.repository,selected.number),
      this.pages(root,`${endpoint}/issues/${selected.number}/comments?per_page=100`),
      this.pages(root,`${endpoint}/pulls/${selected.number}/reviews?per_page=100`),
      this.pages(root,`${endpoint}/pulls/${selected.number}/comments?per_page=100`),
      this.unresolved(root,context.repository,selected.number),
    ]);
    const comments=[...issueComments.map(c=>({kind:'comment',value:c})),...reviews.map(c=>({kind:'review',value:c})),...lineComments.map(c=>({kind:'line',value:c}))].map(({kind,value})=>{
      const c=commentSchema.parse(value);
      return {id:`${kind}-${c.id}`,kind,body:c.body??'',author:c.user?.login??'削除されたユーザー',url:c.html_url,createdAt:c.created_at??c.submitted_at??'',path:c.path??null,line:c.line??c.original_line??null,outdated:kind==='line'&&c.line===null,state:c.state??null};
    }).sort((a,b)=>a.createdAt.localeCompare(b.createdAt));
    return {...result,pullRequest:{...pr,unresolvedThreads,comments,checks:(pr.statusCheckRollup??[]).map((c,i)=>({id:String(i),name:c.name??c.context??'チェック',state:c.conclusion||c.status||c.state||'UNKNOWN',url:c.detailsUrl||c.targetUrl||null}))}};
  }
  private async target(root:string,c:Mutation){
    const context=await this.context(root);
    if(context.repository!==c.repository||context.branch!==c.branch||context.head!==c.expectedHead)throw new Fault('github_stale','リポジトリ、ブランチ、またはコミットが変更されています。更新してから操作してください。',409);
    return context;
  }
  async mutate(root:string,c:Mutation,source?:PullRequestSource){
    // Also invalidate uncertain write outcomes, and detach pre-write in-flight reads.
    const prefix=JSON.stringify([c.repository]).slice(0,-1)+',';
    this.statusCache.invalidate(prefix);
    this.checksCache.invalidate(c.repository+':');
    try{return await this.performMutation(root,c,source);}
    finally{this.statusCache.invalidate(prefix);this.checksCache.invalidate(c.repository+':');}
  }
  private async performMutation(root:string,c:Mutation,source?:PullRequestSource){
    const context=await this.target(root,c);
    if(c.type==='github.push'){
      // An explicit refspec and URL avoid push.default, pushurl, mirror and upstream surprises.
      const remote=(await this.gitRun(root,['remote','get-url','--push','--all','origin'])).trim().split('\n');
      if(remote.length!==1||githubRepository(remote[0])!==context.repository)throw new Fault('github_push_remote','origin の push 先が表示中のリポジトリと一致しません。Git の remote 設定を確認してください。');
      await this.gitRun(root,['-c','remote.origin.mirror=false','push','--no-follow-tags',remote[0],`${context.head}:refs/heads/${context.branch}`]);
      return {ok:true,message:'コミットを push しました。'};
    }
    if(c.type==='github.create'){
      const existing=(await this.pulls(root,context)).find(pr=>pr.state==='open');
      if(existing)throw new Fault('github_pr_exists',`このブランチには PR #${existing.number} があります。更新して確認してください。`,409);
      if(c.base===context.branch)throw new Fault('github_base','作業ブランチとは異なるマージ先を指定してください。');
      const remote=z.object({object:z.object({sha:z.string()})}).parse(await this.api(root,`repos/${context.repository}/git/ref/heads/${encodeURIComponent(context.branch)}`));
      if(remote.object.sha!==context.head)throw new Fault('github_push_required','最新のコミットを push してから PR を作成してください。',409);
      await this.target(root,c);
      const pr=z.object({html_url:z.string()}).parse(await this.api(root,`repos/${context.repository}/pulls`,['--method','POST','-f',`title=${c.title}`,'-f',`body=${c.body}`,'-f',`head=${context.branch}`,'-f',`base=${c.base}`,'-F',`draft=${c.draft}`]));
      return {ok:true,message:'PR を作成しました。',url:pr.html_url};
    }
    const [pr,unresolved,repo]=await Promise.all([this.detail(root,context.repository,c.number),this.unresolved(root,context.repository,c.number),this.repository(root,context.repository)]);
    const binding=await this.source(root,context,source);
    const matches=binding ? binding.number===c.number : pr.headRefName===context.branch&&`${pr.headRepositoryOwner?.login}/${pr.headRepository?.name}`.toLowerCase()===context.repository.toLowerCase();
    if(!matches)throw new Fault('github_pr_mismatch','この作業ブランチの PR ではありません。',409);
    if(pr.headRefOid!==c.expectedPRHead||pr.headRefOid!==context.head)throw new Fault('github_stale','PR とローカルのコミットが一致しません。更新・push 後に再確認してください。',409);
    if(pr.state!=='OPEN'||pr.isDraft||pr.mergeStateStatus!=='CLEAN'||pr.reviewDecision==='CHANGES_REQUESTED'||unresolved>0)throw new Fault('github_merge_blocked','マージできません。Draft、CI、レビュー、未解決コメント、競合を確認してください。',409);
    if(!({merge:repo.allow_merge_commit,squash:repo.allow_squash_merge,rebase:repo.allow_rebase_merge}[c.method]))throw new Fault('github_merge_method','このリポジトリでは選択したマージ方式を利用できません。',409);
    await this.target(root,c);
    // GitHub atomically compares the reviewed head SHA and enforces its branch rules.
    const result=z.object({merged:z.boolean()}).parse(await this.api(root,`repos/${context.repository}/pulls/${c.number}/merge`,['--method','PUT','-f',`sha=${c.expectedPRHead}`,'-f',`merge_method=${c.method}`]));
    if(!result.merged)throw new Fault('github_merge_blocked','GitHub がマージを完了しませんでした。PR の状態を更新してください。',409);
    return {ok:true,message:`PR #${c.number} をマージしました。`};
  }
}
