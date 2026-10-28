import {realpath,stat} from 'node:fs/promises';
import {isAbsolute,relative,resolve,sep} from 'node:path';
import {spawn} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import {Fault} from './contracts.ts';

export const setupCandidates=['scripts/worktree-setup.sh','worktree-setup.sh','.orca/setup.sh','.neuraos/setup.sh','scripts/setup.sh','setup.sh'];
export async function setupPath(root:string,path:string){
  if(isAbsolute(path)||path.split(/[\\/]/).includes('..')||path.includes('\0'))throw new Fault('invalid_setup_path','リポジトリ内の相対パスを指定してください。');
  const base=await realpath(root);
  let target:string;
  try{target=await realpath(resolve(base,path));}catch{throw new Fault('setup_missing','setup scriptが見つかりません。');}
  const rel=relative(base,target);
  if(!rel||rel==='..'||rel.startsWith(`..${sep}`)||isAbsolute(rel)||!(await stat(target)).isFile())throw new Fault('invalid_setup_path','リポジトリ内のファイルを指定してください。');
  return target;
}
export async function detectSetup(root:string){
  const found=await Promise.all(setupCandidates.map(async path=>{try{await setupPath(root,path);return path;}catch{return null;}}));
  return found.filter((path):path is string=>path!==null);
}
// Keep the daemon responsive during installs; cap retained output and terminate the
// process group on timeout/shutdown or parent death via the dedicated pipe owner.
export async function runSetup(root:string,path:string,source:string,signal:AbortSignal,onOutput:(output:string)=>void){
  const script=await setupPath(root,path);
  if(signal.aborted)throw new Error('セットアップを中断しました。');
  await new Promise<void>((resolve,reject)=>{
    const child=spawn(process.execPath,[fileURLToPath(new URL('./setup-host.mjs',import.meta.url)),script],{cwd:root,env:{...process.env,NEURA_PROJECT_ROOT:source,NEURA_WORKTREE_PATH:root},detached:true,stdio:['pipe','pipe','pipe']});
    let output='',stopped=false;
    // EOF is also delivered by the OS when the daemon crashes or is SIGKILLed.
    // Do not kill the owner: it must remain alive to stop and reap the script.
    const stop=()=>{stopped=true;child.stdin.end();};
    child.stdin.on('error',()=>{}); // the owner may already have exited
    const timer=setTimeout(stop,15*60*1000);timer.unref();
    signal.addEventListener('abort',stop,{once:true});
    const append=(data:Buffer)=>{output=(output+data.toString()).slice(-32768);onOutput(output);};
    child.stdout.on('data',append);child.stderr.on('data',append);
    const clean=()=>{clearTimeout(timer);signal.removeEventListener('abort',stop);};
    child.on('error',error=>{clean();reject(error);});
    child.on('close',code=>{clean();if(code===0&&!stopped)resolve();else reject(new Error(stopped?'セットアップを中断しました（終了または15分の制限）。':`セットアップに失敗しました（終了コード ${code}）。`));});
  });
}
