import {test} from 'node:test';
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {mkdtemp,writeFile,readFile,rm} from 'node:fs/promises';
import {fileURLToPath} from 'node:url';

test('private App Server owner stops its descendants when the daemon pipe disappears',async()=>{
  const root=await mkdtemp('/tmp/neura-host-test-'),pidFile=root+'/pids',fixture=root+'/server.mjs';
  await writeFile(fixture,`import {spawn} from 'node:child_process';import {writeFileSync} from 'node:fs';const child=spawn(process.execPath,['-e','process.on("SIGTERM",()=>{});setInterval(()=>{},1000)'],{detached:true,stdio:'ignore'});writeFileSync(${JSON.stringify(pidFile)},JSON.stringify([process.pid,child.pid]));process.on('SIGTERM',()=>{});setInterval(()=>{},1000);`);
  const host=spawn(process.execPath,[fileURLToPath(new URL('../../apps/daemon/src/codex-host.mjs',import.meta.url)),process.execPath,fixture],{detached:true,stdio:'pipe'});host.stdout.resume();host.stderr.resume();
  const alive=(pid:number)=>{try{process.kill(pid,0);return true;}catch(error){if((error as NodeJS.ErrnoException).code==='ESRCH')return false;throw error;}};
  let pids:number[]=[];
  try{
    for(let i=0;i<100;i++){try{pids=JSON.parse(await readFile(pidFile,'utf8'));break;}catch{}await new Promise(r=>setTimeout(r,25));}
    assert.equal(pids.length,2);assert.ok(pids.every(alive));
    // Simulates a daemon crash closing its pipe, without a graceful close RPC.
    host.stdin.end();
    for(let i=0;i<160&&[host.pid!,...pids].some(alive);i++)await new Promise(r=>setTimeout(r,25));
    assert.equal([host.pid!,...pids].some(alive),false,'No App Server or detached command may survive the owner');
  }finally{for(const pid of [host.pid!,...pids])try{process.kill(pid,'SIGKILL');}catch{}await rm(root,{recursive:true,force:true});}
});
