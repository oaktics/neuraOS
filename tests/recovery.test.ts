import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { randomUUID } from 'node:crypto';
import { LocalStore } from '../packages/sync/src/local-store.ts';
import { input,user } from './helpers.ts';
test('SQLite restart retains state and unacknowledged outbox, and ack is transactional',async()=>{
  const dir=await mkdtemp(join(tmpdir(),'neura-store-'));const path=join(dir,'runner.sqlite');const workspace=randomUUID();let store=new LocalStore(path,workspace);
  try{const command={operationId:randomUUID(),command:{type:'task.create' as const,id:randomUUID(),input:input()}};store.apply(command,user);store.enqueue(command);store.close();store=new LocalStore(path,workspace);assert.equal(store.read().tasks.length,1);assert.equal(store.pending().length,1);store.acknowledge(command.operationId,store.read());store.close();store=new LocalStore(path,workspace);assert.equal(store.pending().length,0);assert.equal(store.read().tasks.length,1);}finally{store.close();await rm(dir,{recursive:true,force:true});}
});
test('transaction failure never leaves half of journal+outbox',async()=>{const dir=await mkdtemp(join(tmpdir(),'neura-tx-'));const store=new LocalStore(join(dir,'db'),randomUUID());try{assert.throws(()=>store.transaction(()=>{store.db.prepare('INSERT INTO journal VALUES(?,?,?)').run(randomUUID(),'{}','now');throw new Error('crash');}));assert.equal(store.db.prepare('SELECT count(*) n FROM journal').get()!.n,0);}finally{store.close();await rm(dir,{recursive:true,force:true});}});
test('importing older snapshot applies deletion ledger first',async()=>{const dir=await mkdtemp(join(tmpdir(),'neura-deletion-'));const store=new LocalStore(join(dir,'db'),randomUUID());try{const id=randomUUID();store.apply({operationId:randomUUID(),command:{type:'memory.save',id,expectedVersion:0,input:{kind:'Preference',scope:'workspace',scopeId:null,content:'erase me',evidence:'owner',classification:'standard',explicit:true,expiresAt:null}}},user);const backup=store.read();store.apply({operationId:randomUUID(),command:{type:'memory.delete',id,expectedVersion:1}},user);store.transaction(()=>store.write(backup));assert.equal(store.read().memories.length,0);assert.equal(store.read().tombstones.length,1);}finally{store.close();await rm(dir,{recursive:true,force:true});}});
