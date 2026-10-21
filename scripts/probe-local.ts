import {mkdir,writeFile} from 'node:fs/promises';
import {join,resolve} from 'node:path';
import {randomUUID} from 'node:crypto';
import {CodexAdapter} from '../packages/adapters/codex/index.ts';
import {ClaudeAdapter} from '../packages/adapters/claude/index.ts';
import {emptyState,applyCommand} from '../packages/task-domain/src/index.ts';
import {TaskInput} from '../packages/contracts/src/index.ts';
const results=[];
for(const provider of (process.env.NEURA_PROBE_PROVIDER?[process.env.NEURA_PROBE_PROVIDER as 'codex'|'claude']:['codex','claude'] as const)){
 const adapter=provider==='codex'?new CodexAdapter():new ClaudeAdapter();const caps=await adapter.probeCapabilities();
 const state=applyCommand(emptyState(randomUUID()),{operationId:randomUUID(),command:{type:'task.create',id:randomUUID(),input:TaskInput.parse({title:'ローカルCLI接続試験',objective:'接続試験です。test.txt というテキスト成果物に NEURA_LOCAL_OK とだけ記載して返してください。memoryCandidatesは空です。',provider,criteria:[{id:randomUUID(),description:'NEURA_LOCAL_OK',kind:'contains',value:'NEURA_LOCAL_OK',required:true}],budget:{maxSeconds:90,maxCalls:3,maxTokens:5000,maxUsd:null}})}},{id:'probe',role:'user'});
 const root=resolve('.tmp','local-probe',provider,randomUUID());await mkdir(root,{recursive:true});
 let streamUpdates=0;const chat=process.env.NEURA_PROBE_CHAT==='1';if(chat){state.tasks[0].work={role:'vice_president',parentId:null,conversationId:null,phase:'chat',title:'副社長'};state.tasks[0].objective='表示試験です。日本語で2つのプランを比較するMarkdownの表とTypeScriptのコード例を、短い説明とともに書いてください。最後にNEURA_LOCAL_OKと記載。プロジェクトはないのでproposalsは空です。';}
 const start=Date.now();try{const result=await adapter.execute({task:state.tasks[0],onText:async()=>{streamUpdates++;},memories:[],projectInstructions:'',runtimeDir:root,signal:AbortSignal.timeout(90000),onEvent:async()=>{},onSession:async(_session,model)=>{console.log(JSON.stringify({provider,stage:'session',model}));}});results.push({provider,ok:result.output.artifacts.some(a=>a.content.includes('NEURA_LOCAL_OK')),elapsedMs:Date.now()-start,streamUpdates,calls:result.calls,tokens:result.tokens,version:caps.version});}catch(e){results.push({provider,ok:false,elapsedMs:Date.now()-start,error:e instanceof Error?e.message:'failed',version:caps.version});}console.log(JSON.stringify(results.at(-1)));
}
await mkdir('.tmp/evidence',{recursive:true});await writeFile(join('.tmp/evidence',`local-cli-${process.env.NEURA_PROBE_PROVIDER??'all'}.json`),JSON.stringify({at:new Date().toISOString(),results},null,2));
