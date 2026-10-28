import {test} from 'node:test';
import assert from 'node:assert/strict';
import {mkdtemp,writeFile,rm} from 'node:fs/promises';
import {claudeHistory} from '../../apps/daemon/src/claude-history.ts';

test('Claude byte pagination preserves tool calls/results and handles large transcripts within a bounded window',async()=>{
  const root=await mkdtemp('/tmp/neura-history-'),path=root+'/session.jsonl';
  try{
    const rows=Array.from({length:45},(_,i)=>JSON.stringify({uuid:`m${i}`,type:i%2?'assistant':'user',message:{content:[{type:'text',text:`日本語 ${i}`},{type:i%2?'tool_use':'tool_result',id:`tool${i}`,tool_use_id:`tool${i-1}`,input:{command:'git status'},content:'verified output'}]}}));
    await writeFile(path,rows.join('\n')+'\n');
    const first=await claudeHistory(path);assert.equal(first.data.length,20);assert.equal(first.data[0].id,'m44');assert.match(first.data[0].items[1].text,/verified output/);assert.match(first.data[1].items[1].text,/git status/);
    const second=await claudeHistory(path,first.nextCursor!);assert.equal(second.data[0].id,'m24');
    const third=await claudeHistory(path,second.nextCursor!);assert.equal(third.data.length,5);assert.equal(third.nextCursor,null);
    await assert.rejects(claudeHistory(path,'-1'),/カーソル/);
    await writeFile(path,JSON.stringify({uuid:'huge',message:{content:'x'.repeat(3*1024*1024)}})+'\n'+rows.join('\n')+'\n');
    const large=await claudeHistory(path);assert.equal(large.data[0].id,'m44');assert.ok(large.nextCursor);
    let page=large,loops=0;while(page.nextCursor&&loops++<10)page=await claudeHistory(path,page.nextCursor);assert.ok(loops<10);
  }finally{await rm(root,{recursive:true,force:true});}
});
