import {test} from 'node:test';
import assert from 'node:assert/strict';
import {mkdtemp,writeFile,readFile,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {Terminals} from '../../apps/daemon/src/terminals.ts';
import {Store} from '../../apps/daemon/src/store.ts';

test('workspace stop waits for a child that ignores SIGHUP after its leader exits',async()=>{
  const dir=await mkdtemp(join(tmpdir(),'neura-stop-group-'));
  const program=join(dir,'leader.mjs'),ready=join(dir,'ready');
  await writeFile(program,`#!/usr/bin/env node
import {spawn} from 'node:child_process';
if(process.argv.includes('--help'))process.exit(0);
const child=spawn(process.execPath,['-e',\`const fs=require('node:fs');process.on('SIGHUP',()=>{});fs.writeFileSync(${JSON.stringify(ready)},String(process.pid));setInterval(()=>{},1000);\`],{stdio:'ignore'});
process.on('SIGHUP',()=>process.exit(0));
setInterval(()=>{},1000);
`,{mode:0o700});
  const previous=process.env.NEURA_CODEX_PATH;
  process.env.NEURA_CODEX_PATH=program;
  const store=new Store(':memory:'),terminals=new Terminals(store);
  let childPid:number|undefined;
  try{
    const terminal=await terminals.open({id:'w',projectId:'p',name:'w',path:dir,branch:'main',kind:'worktree',createdAt:''},'codex',false);
    for(let i=0;i<100;i++){
      try{childPid=Number(await readFile(ready,'utf8'));break;}catch{await new Promise(r=>setTimeout(r,25));}
    }
    assert.ok(childPid,'child installed its SIGHUP handler');
    let stopped=false;
    const stopping=terminals.stopWorkspace('w').then(()=>{stopped=true;});
    await new Promise(r=>setTimeout(r,300));
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
