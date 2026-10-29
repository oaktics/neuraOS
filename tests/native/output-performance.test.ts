import {test} from 'node:test';
import assert from 'node:assert/strict';
import {mkdtempSync,rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {Store} from '../../apps/daemon/src/store.ts';

test('batched output preserves interleaved terminal order and resize boundaries',()=>{
  const store=new Store(':memory:');
  try{
    store.append('a','before');store.append('b','other');store.resize('a',120,40);store.append('a','after');
    const output=store.output('a',0);
    assert.deepEqual(output.chunks.map(r=>[r.data,r.cols,r.rows]),[['before',null,null],['',120,40],['after',null,null]]);
    assert.equal(store.output('b',0).data,'other');
    assert.equal(store.output('a',output.cursor).data,'');
  }finally{store.close();}
});
test('close persists the tail across reopen and timer flushes without readers',async()=>{
  const dir=mkdtempSync(join(tmpdir(),'neura-output-test-')),path=join(dir,'db');
  let store=new Store(path);
  try{
    store.append('a','timer');await new Promise(r=>setTimeout(r,50));
    assert.equal(store.db.prepare('SELECT count(*) AS n FROM output').get()!.n,1);
    store.append('a','tail');store.close();store=new Store(path);
    assert.equal(store.output('a',0).data,'timertail');
  }finally{store.close();rmSync(dir,{recursive:true,force:true});}
});
test('failed transaction retains output for a subsequent successful retry',()=>{
  const store=new Store(':memory:');
  try{
    store.db.exec("CREATE TRIGGER fail_output BEFORE INSERT ON output BEGIN SELECT RAISE(ABORT,'test'); END;");
    store.append('a','retained');assert.throws(()=>store.flushOutput());
    store.db.exec('DROP TRIGGER fail_output');
    assert.equal(store.output('a',0).data,'retained');
    assert.equal(store.output('a',0).chunks.length,1);
  }finally{store.close();}
});
test('burst memory is bounded and output remains complete across pages',()=>{
  const store=new Store(':memory:');
  try{
    for(let i=0;i<1000;i++)store.append('a',String(i)+'\n');
    assert.ok(Number(store.db.prepare('SELECT count(*) AS n FROM output').get()!.n)>=768);
    let cursor=0,text='';
    for(;;){const page=store.output('a',cursor);text+=page.data;cursor=page.cursor;if(!page.more)break;}
    assert.equal(text,Array.from({length:1000},(_,i)=>String(i)+'\n').join(''));
  }finally{store.close();}
});

test('workspace deletion cannot resurrect a buffered terminal tail',()=>{
  const store=new Store(':memory:');
  try{
    store.put('terminals',{id:'a',workspaceId:'w',provider:'shell',status:'exited',createdAt:'',cols:80,rows:24});
    store.append('a','pending');store.deleteWorkspace('w');store.flushOutput();
    assert.equal(store.output('a',0).chunks.length,0);
  }finally{store.close();}
});
