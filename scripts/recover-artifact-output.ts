/** Repair legacy artifact-name failures using the matching local Codex output only.
 * Writes a validated generation checkpoint; resumption remains an explicit API action.
 * Usage: pnpm exec tsx scripts/recover-artifact-output.ts <task-id>
 */
import {readFile,readdir} from 'node:fs/promises';import {join} from 'node:path';import {homedir} from 'node:os';
import {AgentOutput,type State} from '../packages/contracts/src/index.ts';import {ensure} from '../packages/policy/src/index.ts';import {saveGeneration,readGeneration} from '../apps/runner/src/generation.ts';
const taskId=process.argv[2];ensure(taskId&&/^[0-9a-f-]{36}$/.test(taskId),'task_id_required');
const dataDir=process.env.NEURA_DATA_DIR??join(homedir(),'Library/Application Support/neuraOS'),token=(await readFile(join(dataDir,'runner-token'),'utf8')).trim();
const response=await fetch(`http://127.0.0.1:${process.env.NEURA_RUNNER_PORT??4317}/api/state`,{headers:{Authorization:`Bearer ${token}`}});ensure(response.ok,'runner_unavailable');const {state}=await response.json() as {state:State};const task=state.tasks.find(t=>t.id===taskId);ensure(task?.status==='blocked'&&task.reason==='invalid_artifact_name','not_artifact_name_failure');const run=task.runs.at(-1);ensure(run?.provider==='codex'&&run.sessionId&&run.calls>0&&run.tokens>0,'no_completed_codex_generation');ensure(Date.parse(run.leaseUntil)<=Date.now(),'lease_held');
const dir=join(dataDir,'runs',run.id),phase=task.work?.phase??'task';ensure(!await readGeneration(dir,run,phase),'checkpoint_already_present');
const sessionDir=join(dir,'agent/home/.codex/sessions');let output:AgentOutput|undefined;let matches=0;
for(const name of (await readdir(sessionDir,{recursive:true})).filter(p=>p.endsWith('.jsonl'))){
 const lines=(await readFile(join(sessionDir,name),'utf8')).split('\n').filter(Boolean).map(line=>JSON.parse(line));
 if(!lines.some(line=>line.type==='session_meta'&&line.payload?.id===run.sessionId))continue;matches++;
 for(const line of lines){const payload=line.payload;if(line.type!=='response_item'||payload?.role!=='assistant'||payload.type!=='message')continue;
  for(const item of payload.content??[]){if(item.type!=='output_text')continue;try{const result=AgentOutput.safeParse(JSON.parse(item.text));if(result.success)output=result.data;}catch{}}
 }
}
ensure(matches===1&&output,'generation_not_found');const checkpoint=await saveGeneration(dir,run,phase,output);console.log(JSON.stringify({taskId,runId:run.id,names:checkpoint.output.artifacts.map(a=>a.name),modelCalls:0,projectFilesModified:false}));
