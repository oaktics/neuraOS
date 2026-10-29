import {test} from 'node:test';
import assert from 'node:assert/strict';
import {spawn,execFileSync} from 'node:child_process';
import {mkdtemp,readFile,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
const binary=process.env.NEURA_NATIVE_DAEMON;
const delay=ms=>new Promise(r=>setTimeout(r,ms));
async function until(check,ms=8000){const end=Date.now()+ms;while(Date.now()<end){if(await check())return;await delay(25);}throw Error('fixture deadline');}
function alive(pid){try{process.kill(pid,0);return true;}catch(e){if(e.code==='ESRCH')return false;throw e;}}
for(const mode of ['eof','sigterm','parent-crash','detached','exit'])test(`native provider-host stops owned descendants: ${mode}`,{skip:!binary,timeout:15000},async()=>{
 const dir=await mkdtemp(join(tmpdir(),'neura-owner-test-'));
 const fixture=join(dir,'fixture'),pidsFile=join(dir,'pids'),writes=join(dir,'writes');
 execFileSync('/usr/bin/cc',['tests/native/fixtures/process-tree.c','-o',fixture]);
 let child,pids=[],stderr='';
 try{
   const args=['provider-host',fixture,pidsFile,writes,mode==='detached'?'detached':mode==='exit'?'exit':'tree'];
   if(mode==='parent-crash'){
     const source=`const{spawn}=require('node:child_process');const c=spawn(process.argv[1],process.argv.slice(2),{stdio:['pipe','inherit','inherit']});console.log(c.pid);setInterval(()=>{},60000);`;
     child=spawn(process.execPath,['-e',source,binary,...args],{stdio:['pipe','pipe','pipe']});
   }else child=spawn(binary,args,{stdio:['pipe','pipe','pipe']});
   child.stderr.on('data',b=>stderr+=b);
   await until(async()=>{try{pids=(await readFile(pidsFile,'utf8')).trim().split('\n').map(Number);return pids.length===2;}catch{return false;}});
   assert.ok(pids.every(pid=>pid>1&&pid!==process.pid));
   if(mode==='sigterm')child.kill('SIGTERM');
   else if(mode==='parent-crash')child.kill('SIGKILL');
   else if(mode!=='exit')child.stdin.end();
   await until(()=>pids.every(pid=>!alive(pid)));
   const before=(await readFile(writes)).length;await delay(100);assert.equal((await readFile(writes)).length,before);
   await until(()=>child.exitCode!==null||child.signalCode!==null);
   assert.equal(stderr,'');
   if(mode==='exit')assert.equal(child.exitCode,7);
 }finally{for(const pid of pids)if(alive(pid))try{process.kill(pid,'SIGKILL');}catch{}if(child&&child.exitCode===null&&child.signalCode===null)child.kill('SIGKILL');await rm(dir,{recursive:true,force:true});}
});
