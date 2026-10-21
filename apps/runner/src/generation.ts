import {randomUUID} from 'node:crypto';
import {open,readFile,rename,unlink} from 'node:fs/promises';
import {join} from 'node:path';
import {z} from 'zod';
import {AgentOutput,type Run,type Artifact} from '../../../packages/contracts/src/index.ts';
import {ensure,contentHash} from '../../../packages/policy/src/index.ts';
const Checkpoint=z.object({version:z.literal(1),runId:z.string().uuid(),planVersion:z.number().int(),phase:z.string(),output:AgentOutput,ids:z.array(z.string().uuid())});
export type Generation=z.infer<typeof Checkpoint>;
export async function readGeneration(dir:string,run:Run,phase:string){
 let raw:string;try{raw=await readFile(join(dir,'generation.json'),'utf8');}catch(e){if((e as NodeJS.ErrnoException).code==='ENOENT')return undefined;throw e;}
 let json:unknown;try{json=JSON.parse(raw);}catch{ensure(false,'generation_checkpoint_invalid');}
 const parsed=Checkpoint.safeParse(json);ensure(parsed.success,'generation_checkpoint_invalid');const value=parsed.data;
 ensure(value.runId===run.id&&value.planVersion===run.planVersion,'generation_checkpoint_invalid');
 if(value.phase!==phase){ensure((value.phase==='planning'&&phase==='reviewing')||(value.phase==='reviewing'&&phase==='finished'),'generation_checkpoint_invalid');return undefined;} // A director's planning and reviewing phases produce separate outputs.
 ensure(value.ids.length===value.output.artifacts.length&&new Set(value.ids).size===value.ids.length,'generation_checkpoint_invalid');return value;
}
export async function saveGeneration(dir:string,run:Run,phase:string,raw:unknown):Promise<Generation>{
 const output=AgentOutput.parse(raw);ensure(new Set(output.artifacts.map(a=>a.name)).size===output.artifacts.length,'duplicate_artifact_name');
 const value:Generation={version:1,runId:run.id,planVersion:run.planVersion,phase,output,ids:output.artifacts.map(()=>randomUUID())};
 const tmp=join(dir,`.generation-${randomUUID()}.tmp`);const file=await open(tmp,'wx',0o600);
 try{await file.writeFile(JSON.stringify(value));await file.sync();}finally{await file.close();}
 try{await rename(tmp,join(dir,'generation.json'));}finally{await unlink(tmp).catch(()=>{});}return value;
}
/** Physical storage uses generated IDs only, regardless of the logical name. */
export async function persistGeneration(dir:string,generation:Generation,existing:()=>Artifact[],add:(id:string,artifact:Generation['output']['artifacts'][number])=>Promise<unknown>){
 for(const [index,artifact] of generation.output.artifacts.entries()){
  const id=generation.ids[index]!,prior=existing().find(a=>a.id===id),digest=contentHash(artifact.content);
  if(prior){ensure(prior.runId===generation.runId&&prior.name===artifact.name&&prior.hash===digest,'artifact_recovery_conflict');continue;}
  const path=join(dir,id);let file;try{file=await open(path,'wx',0o600);await file.writeFile(artifact.content);await file.sync();}catch(e){if((e as NodeJS.ErrnoException).code!=='EEXIST')throw e;}finally{await file?.close();}
  ensure(contentHash(await readFile(path))===digest,'artifact_readback_failed');await add(id,artifact);
 }
}
