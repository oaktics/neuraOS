import {execFile} from 'node:child_process';
import {promisify} from 'node:util';
import {realpath,readdir,readFile,stat,writeFile,rename,unlink} from 'node:fs/promises';
import {dirname,join,resolve,relative,isAbsolute} from 'node:path';
import {randomUUID} from 'node:crypto';
import {Fault} from './contracts.ts';
import {hash} from './store.ts';
const exec=promisify(execFile);
export async function git(cwd:string,args:string[],timeout=30000){
  try{return (await exec('git',['--no-optional-locks','-c','core.quotepath=false',...args],{cwd,maxBuffer:4*1024*1024,timeout,env:{...process.env,GIT_TERMINAL_PROMPT:'0'}})).stdout;}
  catch(e){throw new Fault('git_failed',(e as {stderr?:string}).stderr?.trim()||'Gitの操作に失敗しました。');}
}
export async function projectFolder(path:string){
  const canonical=await realpath(path);
  if(!(await stat(canonical)).isDirectory())throw new Fault('not_directory','フォルダを選択してください。');
  try {return {path:(await git(canonical,['rev-parse','--show-toplevel'])).trim(),isGit:true};}
  catch {return {path:canonical,isGit:false};}
}
export async function scoped(root:string,path:string){
  if(isAbsolute(path)||path.split(/[\\/]/).some(p=>p==='..'||p==='.git')||path.includes('\0'))throw new Fault('invalid_path','このパスにはアクセスできません。');
  const canonicalRoot=await realpath(root),target=await realpath(resolve(root,path)),rel=relative(canonicalRoot,target);
  if(rel==='..'||rel.startsWith('../')||isAbsolute(rel)||rel.split(/[\\/]/).includes('.git'))throw new Fault('invalid_path','このパスにはアクセスできません。');
  return target;
}
export async function files(root:string,path=''){
  const dir=await scoped(root,path);
  const entries=(await readdir(dir,{withFileTypes:true})).filter(e=>!['.git','node_modules','.build','.DS_Store'].includes(e.name)&&!e.isSymbolicLink());
  return {path,entries:entries.map(e=>({name:e.name,path:path?`${path}/${e.name}`:e.name,isDirectory:e.isDirectory()})).sort((a,b)=>Number(b.isDirectory)-Number(a.isDirectory)||a.name.localeCompare(b.name))};
}
export async function file(root:string,path:string){
  const target=await scoped(root,path),info=await stat(target);
  if(!info.isFile()||info.size>1048576)throw new Fault('file_too_large','表示できるのは1MB以下のテキストファイルです。');
  const bytes=await readFile(target);
  if(bytes.includes(0))throw new Fault('binary_file','バイナリファイルは表示できません。');
  const content=bytes.toString('utf8');
  if(!Buffer.from(content).equals(bytes))throw new Fault('file_encoding','UTF-8以外のファイルは編集できません。');
  return {path,content,hash:hash(content)};
}
export async function saveFile(root:string,path:string,content:string,expectedHash:string){
  const previous=await file(root,path);
  if(previous.hash!==expectedHash)throw new Fault('file_conflict','ファイルが外部で更新されています。開き直して変更を確認してください。',409);
  const target=await scoped(root,path),temporary=join(dirname(target),`.neura-${randomUUID()}.tmp`),info=await stat(target);
  try{await writeFile(temporary,content,{mode:info.mode,flag:'wx'});await rename(temporary,target);}finally{await unlink(temporary).catch(()=>{});}
  return {path,content,hash:hash(content)};
}
export async function gitStatus(root:string){
  const raw=await git(root,['status','--porcelain=v1','-z','--untracked-files=normal']),parts=raw.split('\0'),changes=[];
  for(let i=0;i<parts.length;i++){const entry=parts[i];if(!entry)continue;const status=entry.slice(0,2),path=entry.slice(3);changes.push({path,status});if(/[RC]/.test(status))i++;}
  const branch=(await git(root,['branch','--show-current'])).trim()||'(detached)';
  return {branch,changes};
}
export async function diff(root:string,path:string){
  // Deleted files need not exist; Git receives a literal pathspec, never an option.
  if(isAbsolute(path)||path.split(/[\\/]/).some(p=>p==='..'||p==='.git')||path.includes('\0'))throw new Fault('invalid_path','無効なパスです。');
  const status=await gitStatus(root),change=status.changes.find(c=>c.path===path);
  if(!change) return {path,content:'変更はありません。'};
  if(change.status==='??'){const value=await file(root,path);return {path,content:`新規ファイル: ${path}\n\n${value.content}`};}
  return {path,content:await git(root,['diff','--no-ext-diff','--no-textconv','HEAD','--',`:(literal)${path}`])};
}


// Resolve the server's symbolic HEAD each time; cached origin/HEAD can be stale.
export async function fetchDefault(root:string){
  const advertised=await git(root,['ls-remote','--symref','origin','HEAD']);
  const ref=advertised.match(/^ref: (refs\/heads\/.+)	HEAD$/m)?.[1];
  if(!ref)throw new Fault('remote_head_missing','originのデフォルトブランチを取得できません。リモート設定を確認してください。');
  await git(root,['check-ref-format',ref]);
  const branch=ref.slice('refs/heads/'.length);
  await git(root,['fetch','--no-tags','origin',`+${ref}:refs/remotes/origin/${branch}`]);
  const commit=(await git(root,['rev-parse','--verify',`refs/remotes/origin/${branch}^{commit}`])).trim();
  return {branch,commit};
}
export async function syncDefault(root:string,fetched?:Awaited<ReturnType<typeof fetchDefault>>){
  const clean=async()=>{
    if((await git(root,['status','--porcelain=v1','--untracked-files=all'])).trim())
      throw new Fault('workspace_dirty','未コミットの変更・未追跡ファイルがあります。保存・コミットまたは退避してから更新してください。',409);
  };
  await clean();
  const target=fetched??await fetchDefault(root);
  const current=(await git(root,['branch','--show-current'])).trim();
  if(!current)throw new Fault('detached_head','ブランチに切り替えてから更新してください。',409);
  // Never move an existing default branch backwards, or discard divergent commits.
  const exists=(await git(root,['for-each-ref','--format=%(refname)',`refs/heads/${target.branch}`])).trim().split('\n').includes(`refs/heads/${target.branch}`);
  if(exists){
    try{await git(root,['merge-base','--is-ancestor',`refs/heads/${target.branch}`,target.commit]);}
    catch{throw new Fault('local_commits','デフォルトブランチにリモート未反映のコミットがあります。先にマージなどで解消してください。',409);}
  }
  // merge can overwrite ignored files; reject collisions before switching branches.
  const ignored=(await git(root,['ls-files','--others','--ignored','--exclude-standard','-z'])).split('\0').filter(Boolean);
  const tracked=(await git(root,['ls-tree','-r','--name-only','-z',target.commit])).split('\0').filter(Boolean);
  if(ignored.some(a=>tracked.some(b=>a===b||a.startsWith(b+'/')||b.startsWith(a+'/'))))
    throw new Fault('ignored_collision','更新先と重なる無視対象ファイルがあります。退避してから更新してください。',409);
  await clean();
  await git(root,['switch','--no-overwrite-ignore',...(exists?[target.branch]:['-c',target.branch,target.commit])]);
  await git(root,['-c','merge.autostash=false','merge','--ff-only',target.commit]);
  return target;
}
