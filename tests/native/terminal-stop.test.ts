import {test} from 'node:test';
import assert from 'node:assert/strict';
import {mkdtemp,writeFile,readFile,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {execFile} from 'node:child_process';
import {promisify} from 'node:util';
import {Terminals,parseProcessTable,processGroupAlive} from '../../apps/daemon/src/terminals.ts';
import {Store} from '../../apps/daemon/src/store.ts';

test('process table accepts zero PGIDs but rejects malformed rows with an actionable error',()=>{
  assert.deepEqual(parseProcessTable('  1 0 1\n  42 1 0\n'),[{pid:1,parent:0,group:1},{pid:42,parent:1,group:0}]);
  for(const row of ['42 1','42 1 nope','42 1 -1','42 1 2 extra'])
    assert.throws(()=>parseProcessTable(row),{code:'terminal_process_table_invalid'});
});

test('workspace stop preserves terminals on discovery failure and can be retried',async()=>{
  const dir=await mkdtemp(join(tmpdir(),'neura-stop-retry-'));
  const store=new Store(':memory:');
  let mode:'invalid'|'unavailable'|'ready'='invalid';
  const terminals=new Terminals(store,async()=>{
    if(mode==='invalid')return '1 0 invalid';
    if(mode==='unavailable')throw new Error('process table unavailable');
    return (await promisify(execFile)('/bin/ps',['-axo','pid=,ppid=,pgid='])).stdout;
  });
  try{
    const terminal=await terminals.open({id:'w',projectId:'p',name:'w',path:dir,branch:'main',kind:'worktree',createdAt:''},'shell',false);
    await assert.rejects(terminals.stopWorkspace('w'),{code:'terminal_process_table_invalid'});
    assert.equal(store.state().terminals.find(t=>t.id===terminal.id)?.status,'running');
    mode='unavailable';
    await assert.rejects(terminals.stopWorkspace('w'),{code:'terminal_stop_failed'});
    assert.equal(store.state().terminals.find(t=>t.id===terminal.id)?.status,'running');
    mode='ready';
    await terminals.stopWorkspace('w');
    assert.equal(store.state().terminals.find(t=>t.id===terminal.id)?.status,'exited');
  }finally{await terminals.shutdown();store.close();await rm(dir,{recursive:true,force:true});}
});

for(const mode of ['same-group','detached','interactive-shell'] as const)test(`workspace stop waits for SIGHUP-ignoring jobs: ${mode}`,async()=>{
  const dir=await mkdtemp(join(tmpdir(),'neura-stop-group-'));
  const program=join(dir,'leader.mjs'),ready=join(dir,'ready');
  await writeFile(program,`#!/usr/bin/env node
import {spawn} from 'node:child_process';
if(process.argv.includes('--help'))process.exit(0);
const child=spawn(process.execPath,['-e',\`const fs=require('node:fs');process.on('SIGHUP',()=>{});fs.writeFileSync(${JSON.stringify(ready)},String(process.pid));setInterval(()=>{},1000);\`],{stdio:'ignore',detached:${mode==='detached'}});
process.on('SIGHUP',()=>process.exit(0));
setInterval(()=>{},1000);
`,{mode:0o700});
  const previous=process.env.NEURA_CODEX_PATH;
  process.env.NEURA_CODEX_PATH=program;
  // Include a zero-PGID descendant in real process snapshots. It must neither
  // abort stopping other jobs nor signal group 0 (the test runner's own group).
  let childPid:number|undefined;
  const store=new Store(':memory:'),terminals=new Terminals(store,async()=>{
    const {stdout}=await promisify(execFile)('/bin/ps',['-axo','pid=,ppid=,pgid=']);
    return stdout+`\n2147483646 ${childPid??0} 0\n`;
  });
  try{
    const terminal=await terminals.open({id:'w',projectId:'p',name:'w',path:dir,branch:'main',kind:'worktree',createdAt:''},mode==='interactive-shell'?'shell':'codex',false);
    if(mode==='interactive-shell')terminals.input(terminal.id,'test',`${JSON.stringify(program)}\n`);
    for(let i=0;i<100;i++){
      try{const pid=Number(await readFile(ready,'utf8'));if(Number.isSafeInteger(pid)&&pid>0){childPid=pid;break;}}catch{}
      // File creation can be observed before writeFileSync has written the PID.
      await new Promise(r=>setTimeout(r,25));
    }
    assert.ok(childPid,'child installed its SIGHUP handler');
    let stopped=false;
    const stopping=terminals.stopWorkspace('w').then(()=>{stopped=true;});
    // Wait for the observable leader exit instead of assuming process discovery
    // and PTY delivery finish within 300 ms on a busy CI runner.
    for(let i=0;i<40&&store.state().terminals.find(t=>t.id===terminal.id)?.status==='running';i++)await new Promise(r=>setTimeout(r,25));
    assert.equal(store.state().terminals.find(t=>t.id===terminal.id)?.status,'exited');
    process.kill(childPid,0);
    assert.equal(stopped,false,'leader exit must not resolve group cleanup');
    await stopping;
    assert.throws(()=>process.kill(childPid!,0),{code:'ESRCH'});
  }finally{
    if(childPid)try{process.kill(childPid,'SIGKILL');}catch{}
    await terminals.shutdown();store.close();
    if(previous===undefined)delete process.env.NEURA_CODEX_PATH;else process.env.NEURA_CODEX_PATH=previous;
    await rm(dir,{recursive:true,force:true});
  }
});

test('group liveness waits on EPERM, only ESRCH proves exit, and zero is never probed',()=>{
  const probes:number[]=[];
  assert.equal(processGroupAlive(42,(pid,signal)=>{probes.push(pid);assert.equal(signal,0);}),true);
  assert.deepEqual(probes,[-42]);
  for(const [code,alive] of [['EPERM',true],['ESRCH',false]] as const){
    assert.equal(processGroupAlive(42,()=>{throw Object.assign(new Error(code),{code});}),alive);
  }
  assert.throws(()=>processGroupAlive(42,()=>{throw Object.assign(new Error('unexpected'),{code:'EINVAL'});}),{code:'EINVAL'});
  assert.throws(()=>processGroupAlive(0,()=>assert.fail('must not probe own group')));
});
