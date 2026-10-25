import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtemp,readFile,rm,stat,mkdir} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {randomUUID} from 'node:crypto';
import {Diagnostics} from '../../apps/daemon/src/diagnostics.ts';
import {createDaemon} from '../../apps/daemon/src/server.ts';

test('diagnostics correlate successful and failed commands without storing bodies or tokens',async()=>{
  const root=await mkdtemp(join(tmpdir(),'neura-diagnostics-'));
  const folder=join(root,'private-customer-folder');await mkdir(folder);
  const daemon=await createDaemon(root);
  try {
    const success=randomUUID(),failure=randomUUID();
    const send=(operationId:string,command:unknown)=>daemon.app.inject({method:'POST',url:'/v1/commands',headers:{authorization:`Bearer ${daemon.token}`},payload:{operationId,command}});
    assert.equal((await send(success,{type:'project.add',path:folder})).statusCode,200);
    assert.equal((await send(failure,{type:'terminal.input',terminalId:randomUUID(),clientId:randomUUID(),data:'SECRET-TERMINAL-INPUT'})).statusCode,404);
    await daemon.app.close();
    const text=await readFile(join(root,'diagnostics/daemon.jsonl'),'utf8');
    for(const secret of [folder,daemon.token,'SECRET-TERMINAL-INPUT']) assert.equal(text.includes(secret),false);
    const events=text.trim().split('\n').map(x=>JSON.parse(x));
    assert.deepEqual(events.filter(e=>e.operationId===success).map(e=>e.event),['operation.received','operation.executing','operation.success']);
    assert.ok(events.some(e=>e.operationId===failure&&e.event==='operation.failure'));
    assert.equal((await stat(join(root,'diagnostics/daemon.jsonl'))).mode&0o777,0o600);
  } finally {await daemon.app.close();await rm(root,{recursive:true,force:true});}
});

test('diagnostic storage rotates and storage failures do not reject operations',async()=>{
  const root=await mkdtemp(join(tmpdir(),'neura-diagnostics-'));
  try {
    const log=new Diagnostics(root,1);
    log.record('daemon.start');await log.flush();
    log.record('daemon.end');await log.flush();
    assert.match(await readFile(join(root,'daemon.previous.jsonl'),'utf8'),/daemon.start/);
    assert.match(await readFile(join(root,'daemon.jsonl'),'utf8'),/daemon.end/);
    const invalid=new Diagnostics(join(root,'daemon.jsonl','impossible'));
    invalid.record('daemon.start');await invalid.flush();
  } finally {await rm(root,{recursive:true,force:true});}
});
