import {test} from 'node:test';
import assert from 'node:assert/strict';
import {EventEmitter} from 'node:events';
import {waitForStateInvalidations} from '../native/fixtures/state-invalidation-barrier.mjs';
function fixture(){
 const ws=new EventEmitter(),events=[];
 ws.on('message',bytes=>events.push(JSON.parse(bytes)));
 return {ws,events,send:event=>ws.emit('message',JSON.stringify(event))};
}
test('HTTP exit and all output events can precede state notifications; barrier waits for every target',async()=>{
 const f=fixture(),ids=['a','b'];
 f.send({type:'ready'});
 const after=f.events.length;
 // This is the CI failure interleaving: reconnect is ready, HTTP already shows
 // exited, output invalidations arrive, but the stateful stream batch is later.
 f.send({type:'changed',state:false,terminals:ids});
 assert.ok(ids.every(id=>f.events.slice(after).some(e=>e.type==='changed'&&e.terminals?.includes(id))),'old wait exits here');
 assert.equal(f.events.some(e=>e.type==='changed'&&e.state),false,'old immediate assertion fails here');
 let completed=false;
 const wait=waitForStateInvalidations(f,ids,after).then(()=>{completed=true;});
 await Promise.resolve();assert.equal(completed,false);
 f.send({type:'changed',state:true,terminals:['unrelated']});
 f.send({type:'changed',state:true,terminals:['a']});
 await Promise.resolve();assert.equal(completed,false,'one target is still missing');
 f.send({type:'changed',state:true,terminals:['b']});
 await wait;assert.equal(completed,true);
 assert.equal(f.ws.listenerCount('message'),1,'only the collector remains');
});
test('old state events do not satisfy exit barrier, and a missing notification fails',async()=>{
 const f=fixture();f.send({type:'changed',state:true,terminals:['a']});
 const after=f.events.length;
 f.send({type:'changed',state:false,terminals:['a']});
 await assert.rejects(waitForStateInvalidations(f,['a'],after,0),/missing 1\/1/);
 assert.equal(f.ws.listenerCount('message'),1);
});
test('already-received state notifications satisfy the barrier without another message',async()=>{
 const f=fixture();f.send({type:'changed',state:true,terminals:['a','b']});
 await waitForStateInvalidations(f,['a','b']);
});
for(const event of ['close','error'])test(`stream ${event} fails an incomplete barrier instead of passing`,async()=>{
 const f=fixture();const wait=waitForStateInvalidations(f,['a']);f.ws.emit(event);
 await assert.rejects(wait,/stream (closed|failed)/);
 assert.equal(f.ws.listenerCount('message'),1);
});
