import { spawn, type ChildProcessWithoutNullStreams } from 'node:child_process';
import { mkdir, realpath } from 'node:fs/promises';
import { resolve } from 'node:path';
import { ensure } from '../../policy/src/index.ts';

function literal(path:string){return JSON.stringify(path);}
export function macProfile(executable:string,runtime:string,port:number,readRoots:string[]=[]){
  const ancestors=new Set(['/']);for(const path of [executable,runtime,...readRoots]){const parts=path.split('/');for(let i=1;i<parts.length;i++)ancestors.add(parts.slice(0,i).join('/')||'/');}
  return `(version 1)
    (deny default)
    (allow process-fork)
    (allow process-info* (target self))
    (allow signal (target children))
    (allow sysctl-read)
    (allow mach-lookup)
    (allow user-preference-read (preference-domain "com.openai.codex"))
    (allow ipc-posix-shm-read-data (ipc-posix-name "apple.shm.notification_center") (ipc-posix-name "apple.cfprefs.${process.getuid?.()??501}v1") (ipc-posix-name "apple.cfprefs.daemonv1"))
    (allow file-read-metadata)
    (allow file-map-executable)
    (allow file-read-data (subpath "/System") (subpath "/usr") (subpath "/Library/Apple") (subpath "/Library/Managed Preferences") (subpath "/opt/homebrew/Cellar") (subpath "/opt/homebrew/opt")
      (subpath "/private/var/db/timezone") (subpath "/private/etc") (subpath "/dev") (literal ${literal(executable)}) (subpath ${literal(runtime)}) ${[...ancestors].map(p=>`(literal ${literal(p)})`).join(' ')} ${readRoots.map(p=>`(subpath ${literal(p)})`).join(' ')})
    (allow file-write* (subpath ${literal(runtime)}) (literal "/dev/null") (literal "/dev/tty"))
    (allow process-exec (literal ${literal(executable)}))
    (allow network-outbound (remote ip "localhost:${port}"))
  `;
}
export async function spawnIsolated(command:string,args:string[],runtime:string,port:number,env:Record<string,string|undefined>,readRoots:string[]=[]):Promise<ChildProcessWithoutNullStreams>{
  ensure(process.platform==='darwin','agent_isolation_unsupported','このOSではエージェント隔離がまだ検証されていません。');
  await mkdir(runtime,{recursive:true,mode:0o700});const executable=await realpath(command);const root=await realpath(runtime);
  return spawn('/usr/bin/sandbox-exec',['-p',macProfile(executable,root,port,readRoots),executable,...args],{cwd:root,env,stdio:['pipe','pipe','pipe'],detached:true});
}
export function stopProcessGroup(child:ChildProcessWithoutNullStreams){
  if(child.exitCode!==null||!child.pid)return;
  try{process.kill(-child.pid,'SIGTERM');}catch{}
  const timer=setTimeout(()=>{try{process.kill(-child.pid!,'SIGKILL');}catch{}},2000);timer.unref();child.once('exit',()=>clearTimeout(timer));
}
export async function runNodeTest(content:string,test:string,workdir:string,signal:AbortSignal):Promise<{passed:boolean;evidence:string}>{
  const {writeFile,readFile}=await import('node:fs/promises');const dir=resolve(workdir);await mkdir(dir,{recursive:true,mode:0o700});
  await writeFile(resolve(dir,'artifact.mjs'),content,{mode:0o600});await writeFile(resolve(dir,'verification.mjs'),test,{mode:0o600});
  const name=`neura-test-${crypto.randomUUID()}`;
  return new Promise((done)=>{
    const child=spawn('docker',['run','--rm','--name',name,'--network','none','--read-only','--cap-drop','ALL','--security-opt','no-new-privileges','--pids-limit','64','--memory','128m','--cpus','1','--user',`${process.getuid?.()??1000}:${process.getgid?.()??1000}`,'--mount',`type=bind,source=${dir},target=/work,readonly`,'--workdir','/work','node:24-alpine','node','--test','verification.mjs'],{stdio:['ignore','pipe','pipe']});
    let output='';let settled=false;const finish=(passed:boolean,evidence:string)=>{if(settled)return;settled=true;clearTimeout(timer);signal.removeEventListener('abort',abort);done({passed,evidence:evidence.slice(-10000)});};
    const abort=()=>{spawn('docker',['rm','-f',name],{stdio:'ignore'}).on('error',()=>{});child.kill();finish(false,'container_interrupted');};
    const timer=setTimeout(abort,30000);signal.addEventListener('abort',abort,{once:true});
    child.stdout.on('data',b=>{output=(output+b).slice(-10000);});child.stderr.on('data',b=>{output=(output+b).slice(-10000);});child.on('error',()=>finish(false,'docker_unavailable'));child.on('exit',code=>finish(code===0,`Docker network=none, node --test, exit=${code}\n${output}`));if(signal.aborted)abort();
  });
}
