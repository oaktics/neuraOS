import {test,mock} from 'node:test';
import assert from 'node:assert/strict';
import {mkdtemp,writeFile,rm,open,appendFile} from 'node:fs/promises';
import {claudeCompletion} from '../../apps/daemon/src/claude-completion.ts';

test('completion recovery requires a flushed end marker for the exact session and current turn',async()=>{
  const root=await mkdtemp('/tmp/neura-claude-completion-'),path=root+'/session.jsonl';
  const at=Date.now(),row=(type:string,extra={})=>({type,sessionId:'root',timestamp:new Date(at).toISOString(),...extra});
  const assistant=row('assistant',{message:{content:[{type:'text',text:'Verified result'}]}});
  const end=row('system',{subtype:'turn_duration'});
  const write=async(rows:unknown[],tail='')=>writeFile(path,rows.map(r=>JSON.stringify(r)).join('\n')+'\n'+tail);
  try{
    await write([assistant]);assert.equal(await claudeCompletion(path,'root',at),undefined);
    await write([assistant,end]);assert.equal((await claudeCompletion(path,'root',at))?.last_assistant_message,'Verified result');
    assert.equal(await claudeCompletion(path,'other',at),undefined);
    assert.equal(await claudeCompletion(path,'root',at+1),undefined);
    for(const next of [row('user'),row('assistant'),row('api-request')]){
      await write([assistant,end,next]);assert.equal(await claudeCompletion(path,'root',at),undefined,'new work invalidates old completion');
    }
    await write([assistant,{...end,isSidechain:true}]);assert.equal(await claudeCompletion(path,'root',at),undefined);
    await write([assistant,end],'{"type":"user"');assert.equal(await claudeCompletion(path,'root',at),undefined);
    await write([assistant,end,row('system',{subtype:'away_summary'})]);assert.ok(await claudeCompletion(path,'root',at));
    await write([{padding:'x'.repeat(600000)},assistant,end]);assert.ok(await claudeCompletion(path,'root',at),'bounded tail skips oversized prior records');
    assert.equal(await claudeCompletion(root+'/missing','root',at),undefined);
  }finally{await rm(root,{recursive:true,force:true});}
});


test('a new prompt appended after stat invalidates a stale completion snapshot',async()=>{
  const root=await mkdtemp('/tmp/neura-completion-race-'),path=root+'/session.jsonl';
  const sessionId='root',timestamp=new Date().toISOString();
  await writeFile(path,JSON.stringify({type:'system',subtype:'turn_duration',sessionId,timestamp})+'\n');
  const handle=await open(path),prototype=Object.getPrototypeOf(handle),original=prototype.stat;
  await handle.close();let appended=false;
  const patched=mock.method(prototype,'stat',async function(this:any,...args:any[]){
    const result=await original.apply(this,args);
    if(!appended){appended=true;await appendFile(path,JSON.stringify({type:'user',sessionId,timestamp,message:{content:'new work'}})+'\n');}
    return result;
  });
  try{assert.equal(await claudeCompletion(path,sessionId,0),undefined);assert.equal(appended,true);}
  finally{patched.mock.restore();await rm(root,{recursive:true,force:true});}
});
