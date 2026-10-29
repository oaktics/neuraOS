import {test} from 'node:test';
import assert from 'node:assert/strict';
import {mkdtemp,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {createDaemon} from '../../apps/daemon/src/server.ts';
import {SessionNames} from '../../apps/daemon/src/session-names.ts';

test('state stays available while provider title lookup is blocked',async()=>{
  const directory=await mkdtemp(join(tmpdir(),'neura-state-latency-'));
  const daemon=await createDaemon(directory),original=SessionNames.prototype.refresh;
  let release!:()=>void;
  const blocked=new Promise<void>(resolve=>{release=resolve;});
  SessionNames.prototype.refresh=()=>blocked;
  let timer:NodeJS.Timeout|undefined;
  try{
    const response=await Promise.race([
      daemon.app.inject({url:'/v1/state',headers:{authorization:`Bearer ${daemon.token}`}}),
      new Promise<never>((_,reject)=>{timer=setTimeout(()=>reject(new Error('state waited for provider title lookup')),1000);}),
    ]);
    assert.equal(response.statusCode,200);assert.equal(response.json().protocolVersion,1);
  }finally{
    clearTimeout(timer);release();SessionNames.prototype.refresh=original;
    await daemon.app.close();await rm(directory,{recursive:true,force:true});
  }
});
