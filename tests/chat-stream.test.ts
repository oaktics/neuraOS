import {test} from 'node:test';import assert from 'node:assert/strict';
import {chatTextEmitter} from '../packages/adapters/chat-stream.ts';
import {input} from './helpers.ts';
import type {AdapterContext} from '../packages/adapters/index.ts';
test('incremental structured output exposes only public reply and preserves Japanese markdown',async()=>{
 const reply='## 比較\n\n**日本語**の表です。\\パス\n\n| A | B |\n|---|---|\n| 1 | 2 |',seen:string[]=[];
 const context={task:{...input(),work:{role:'vice_president'}},onText:async(text:string)=>{seen.push(text);}} as unknown as AdapterContext;
 const emitter=chatTextEmitter(context),json=JSON.stringify({summary:'NOT_PUBLIC_SUMMARY',artifacts:[{name:'response.json',content:JSON.stringify({reply,proposals:[]}),mediaType:'application/json'}],memoryCandidates:[]});
 for(let i=1;i<=json.length;i+=7){emitter.push(json.slice(0,i));await emitter.flush();}emitter.push(json);await emitter.flush();
 assert.ok(seen.length>5);assert.equal(seen.at(-1),reply);assert.ok(seen.every((text,i)=>text.startsWith(seen[i-1]??'')&&!text.includes('NOT_PUBLIC_SUMMARY')));
});
