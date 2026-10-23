import {test} from 'node:test';
import assert from 'node:assert/strict';
import {mkdtemp,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {createDaemon} from '../../apps/daemon/src/server.ts';
import type {TerminalRecord} from '../../apps/daemon/src/contracts.ts';

test('notification journal preserves rapid transitions, paginates, survives restart, and cleans up with workspace',async()=>{
  const directory=await mkdtemp(join(tmpdir(),'neura-notification-journal-'));
  let daemon=await createDaemon(directory);
  const terminal:TerminalRecord={id:'t',workspaceId:'w',provider:'codex',status:'exited',createdAt:'',cols:80,rows:24};
  const get=(after:number)=>daemon.app.inject({url:`/v1/notifications?after=${after}`,headers:{authorization:`Bearer ${daemon.token}`}});
  try {
    assert.equal((await daemon.app.inject('/v1/notifications')).statusCode,401);
    daemon.store.put('terminals',terminal);
    const baseline=daemon.store.state().revision;
    // No client poll between transitions, including multiple pages of backlog.
    for(let index=0;index<258;index++) {
      daemon.store.put('terminals',terminal,{id:`e${index}`,terminalId:'t',workspaceId:'w',provider:'codex',kind:index%2?'completed':'waiting',createdAt:''});
    }
    const first=(await get(baseline)).json();
    assert.equal(first.events.length,256);assert.equal(first.more,true);
    assert.deepEqual(first.events.slice(0,2).map((event:{kind:string})=>event.kind),['waiting','completed']);
    assert.deepEqual((await get(baseline)).json(),first); // Reads do not destroy another client's backlog.
    await daemon.app.close();
    daemon=await createDaemon(directory);
    const second=(await get(first.cursor)).json();
    assert.deepEqual(second.events.map((event:{id:string})=>event.id),['e256','e257']);
    assert.equal(second.more,false);
    assert.deepEqual((await get(second.cursor)).json(),{events:[],cursor:second.cursor,more:false});
    const invalid=await daemon.app.inject({url:'/v1/notifications?after=-1',headers:{authorization:`Bearer ${daemon.token}`}});
    assert.equal(invalid.statusCode,400);
    daemon.store.deleteWorkspace('w');
    assert.deepEqual((await get(baseline)).json().events,[]);
  } finally {await daemon.app.close();await rm(directory,{recursive:true,force:true});}
});

test('notification write failure rolls back terminal state and revision atomically',async()=>{
  const {Store}=await import('../../apps/daemon/src/store.ts');
  const store=new Store(':memory:');
  try {
    const terminal:TerminalRecord={id:'t',workspaceId:'w',provider:'claude',status:'running',activity:'working',createdAt:'',cols:80,rows:24};
    store.put('terminals',terminal);
    const revision=store.state().revision;
    store.db.exec("CREATE TRIGGER reject_notification BEFORE INSERT ON notification_events BEGIN SELECT RAISE(ABORT, 'test write failure'); END;");
    assert.throws(()=>store.put('terminals',{...terminal,activity:'waiting'},{id:'e',terminalId:'t',workspaceId:'w',provider:'claude',kind:'waiting',createdAt:''}));
    assert.deepEqual(store.get('terminals','t'),terminal);
    assert.equal(store.state().revision,revision);
    assert.equal(store.notifications(revision).events.length,0);
  } finally {store.close();}
});
