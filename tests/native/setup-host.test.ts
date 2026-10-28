import {test} from 'node:test';
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {mkdtemp,writeFile,readFile,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {once} from 'node:events';
import {runSetup} from '../../apps/daemon/src/worktree-setup.ts';

const delay=(ms:number)=>new Promise(resolve=>setTimeout(resolve,ms));
const alive=(pid:number)=>{try{process.kill(pid,0);return true;}catch(error){if((error as NodeJS.ErrnoException).code==='ESRCH')return false;throw error;}};
async function eventually(check:()=>Promise<boolean>){
  for(let i=0;i<200;i++){if(await check())return;await delay(25);}
  assert.fail('process condition did not settle');
}

for(const mode of ['SIGKILL','crash','shutdown','timeout'] as const)test(`setup stops child/grandchild writes after parent ${mode}`,async()=>{
  const root=await mkdtemp(join(tmpdir(),'neura-setup-owner-'));
  const pidFile=join(root,'pids'),writes=join(root,'writes');
  // Both shell and grandchild ignore TERM; cleanup must reach the whole group.
  await writeFile(join(root,'writer.mjs'),`import {appendFileSync} from 'node:fs';
    process.on('SIGTERM',()=>{});
    appendFileSync(${JSON.stringify(pidFile)},process.pid+'\\n');
    setInterval(()=>appendFileSync(${JSON.stringify(writes)},'x'),10);`);
  await writeFile(join(root,'setup.sh'),`trap '' TERM\necho $$ > pids\n"${process.execPath}" writer.mjs &\nwait\n`);
  const moduleURL=new URL('../../apps/daemon/src/worktree-setup.ts',import.meta.url).href;
  await writeFile(join(root,'parent.mjs'),`import {runSetup} from ${JSON.stringify(moduleURL)};
    const controller=new AbortController();
    const timer=globalThis.setTimeout;
    ${mode==='timeout'?'globalThis.setTimeout=(fn,ms,...args)=>timer(fn,ms===900000?1200:ms,...args);':''}
    ${mode==='shutdown'?'timer(()=>controller.abort(),1200);':''}
    ${mode==='crash'?'timer(()=>{throw new Error("simulated daemon crash");},1200);':''}
    try{await runSetup(${JSON.stringify(root)},'setup.sh',${JSON.stringify(root)},controller.signal,()=>{});process.exitCode=2;}
    catch(error){console.error(error.message);process.exitCode=0;}`);
  const parent=spawn(process.execPath,['--import','tsx',join(root,'parent.mjs')],{stdio:['ignore','pipe','pipe']});
  const exited=once(parent,'exit');
  let stderr='';parent.stdout.resume();parent.stderr.on('data',data=>stderr+=data);
  let pids:number[]=[];
  try{
    await eventually(async()=>{try{pids=(await readFile(pidFile,'utf8')).trim().split('\n').map(Number);return pids.length===2&&(await readFile(writes,'utf8')).length>0;}catch{return false;}});
    assert.ok(pids.every(pid=>pid>1&&alive(pid)));
    if(mode==='SIGKILL')parent.kill('SIGKILL');
    const [code,signal]=await exited;
    if(mode==='SIGKILL')assert.equal(signal,'SIGKILL');
    else if(mode==='crash'){assert.equal(code,1);assert.match(stderr,/simulated daemon crash/);}
    else{assert.equal(code,0);assert.match(stderr,/セットアップを中断/);}
    await eventually(async()=>pids.every(pid=>!alive(pid)));
    const contents=await readFile(writes,'utf8');await delay(250);
    assert.equal(await readFile(writes,'utf8'),contents,'orphaned setup must not keep writing');
  }finally{
    parent.kill('SIGKILL');
    for(const pid of pids)if(pid>1)try{process.kill(pid,'SIGKILL');}catch{}
    await rm(root,{recursive:true,force:true});
  }
});

test('setup preserves output cap, environment, exit codes and pre-aborted safety',async()=>{
  const root=await mkdtemp(join(tmpdir(),'neura-setup-result-'));
  try{
    await writeFile(join(root,'setup.sh'),'printf "%s\\n" "$NEURA_PROJECT_ROOT" "$NEURA_WORKTREE_PATH"; echo stderr >&2');
    let output='';const controller=new AbortController();
    await runSetup(root,'setup.sh','source-root',controller.signal,value=>output=value);
    assert.match(output,/source-root/);assert.ok(output.includes(root));assert.match(output,/stderr/);
    await writeFile(join(root,'setup.sh'),'head -c 40000 /dev/zero; exit 7');
    await assert.rejects(runSetup(root,'setup.sh',root,controller.signal,value=>output=value),/終了コード 7/);
    assert.equal(output.length,32768);
    controller.abort();
    await assert.rejects(runSetup(root,'setup.sh',root,controller.signal,()=>assert.fail('must not launch')),/中断/);
  }finally{await rm(root,{recursive:true,force:true});}
});

test('setup owner never signals PGID 0 or an absent spawn PID',async()=>{
  const hostURL=new URL('../../apps/daemon/src/setup-host.mjs',import.meta.url).href;
  for(const pid of [0,undefined]){
    const source=`import childProcess from 'node:child_process';
      import {EventEmitter} from 'node:events';
      import {syncBuiltinESMExports} from 'node:module';
      childProcess.spawn=()=>{const child=new EventEmitter();child.pid=${pid};
        setImmediate(()=>child.emit('exit',0));return child;};
      syncBuiltinESMExports();
      process.kill=()=>{process.stderr.write('unsafe signal');throw new Error('must not signal');};
      process.argv[2]='unused.sh';await import(${JSON.stringify(hostURL)});`;
    const owner=spawn(process.execPath,['--input-type=module','-e',source],{stdio:['pipe','pipe','pipe']});
    let stderr='';owner.stdout.resume();owner.stderr.on('data',data=>stderr+=data);
    const [code]=await once(owner,'exit');
    assert.equal(code,0,stderr);assert.equal(stderr,'');
  }
});
