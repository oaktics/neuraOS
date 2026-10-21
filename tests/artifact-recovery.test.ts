import {test} from 'node:test';import assert from 'node:assert/strict';import {mkdtemp,mkdir,readFile,writeFile,rm,readdir} from 'node:fs/promises';import {tmpdir} from 'node:os';import {join} from 'node:path';import {randomUUID} from 'node:crypto';
import {ArtifactName,artifactDownloadName,providerArtifactNamePattern} from '../packages/contracts/src/artifact-name.ts';
import {AgentOutput,type Artifact,type Run} from '../packages/contracts/src/index.ts';
import {safeArtifactName,contentHash} from '../packages/policy/src/index.ts';
import {saveGeneration,readGeneration,persistGeneration} from '../apps/runner/src/generation.ts';
import {setup,runner} from './helpers.ts';
const output={summary:'生成したコード案。プロジェクトへの反映やテスト実行は未実施。',artifacts:[{name:'apps/desktop/src/main.tsx',content:'export const value=1;',mediaType:'text/plain' as const},{name:'tests/desktop/main.tsx',content:'test proposal',mediaType:'text/plain' as const}],memoryCandidates:[]};
test('logical artifact names share validation across provider schema and domain',()=>{
 for(const name of ['report.md','src/main.tsx','tests/fixtures/sidebar-tasks.ts','日本語/仕様と引き継ぎ.md','.github/workflows/check.yml']){assert.equal(ArtifactName.parse(name),name);assert.equal(safeArtifactName(name),name);}
 for(const name of ['', '.', '..', '/tmp/x', '../x', 'src/../x', 'src/./x', 'src//x','src/', 'C:/x', 'C:x','\\\\host\\x','src\\x','file\n','file\u0000.txt','file\u007f.txt','a\u2028b']){assert.equal(ArtifactName.safeParse(name).success,false,name);assert.throws(()=>safeArtifactName(name),/invalid_artifact_name/);}
 assert.equal(artifactDownloadName('apps/desktop/src/main.tsx'),'main.tsx');
 const x=setup();x.queue();x.claim();for(const a of AgentOutput.parse(output).artifacts)x.apply({type:'artifact.add',...x.lease,id:randomUUID(),...a},runner);assert.equal(x.task.artifacts.length,2);assert.notEqual(x.task.artifacts[0].name,x.task.artifacts[1].name);
});
test('partial artifact registration resumes from durable output without duplicate artifacts or path writes',async()=>{
 const dir=await mkdtemp(join(tmpdir(),'neura-artifact-recovery-')),run={id:randomUUID(),planVersion:1} as Run;const existing:Artifact[]=[];
 const add=async(id:string,a:AgentOutput['artifacts'][number])=>{existing.push({...a,id,runId:run.id,hash:contentHash(a.content),size:Buffer.byteLength(a.content),createdAt:new Date().toISOString(),cloudKey:null,cloudVerifiedAt:null});};
 try{
  const checkpoint=await saveGeneration(dir,run,'work',output);let count=0;
  await assert.rejects(()=>persistGeneration(dir,checkpoint,()=>existing,async(id,a)=>{if(++count===2)throw Error('simulated registration interruption');await add(id,a);}),/interruption/);
  assert.equal(existing.length,1);const restored=await readGeneration(dir,run,'work');assert.ok(restored);
  await persistGeneration(dir,restored,()=>existing,add);await persistGeneration(dir,restored,()=>existing,add);assert.equal(existing.length,2);assert.deepEqual(existing.map(a=>a.id),checkpoint.ids);
  for(const [i,id] of checkpoint.ids.entries())assert.equal(await readFile(join(dir,id),'utf8'),output.artifacts[i].content);
  assert.deepEqual((await readdir(dir)).sort(),['generation.json',...checkpoint.ids].sort());
  await assert.rejects(()=>readGeneration(dir,{...run,id:randomUUID()},'work'),/generation_checkpoint_invalid/);
  await writeFile(join(dir,'generation.json'),'{bad');await assert.rejects(()=>readGeneration(dir,run,'work'),/generation_checkpoint_invalid/);
 }finally{await rm(dir,{recursive:true,force:true});}
});
test('invalid artifact output is rejected before any artifact file is created',async()=>{
 const dir=await mkdtemp(join(tmpdir(),'neura-invalid-output-'));try{await assert.rejects(()=>saveGeneration(dir,{id:randomUUID(),planVersion:1} as Run,'work',{...output,artifacts:[output.artifacts[0],{...output.artifacts[1],name:'../../outside'}]}));assert.deepEqual(await readdir(dir),[]);}finally{await rm(dir,{recursive:true,force:true});}
});

test('Runner completes cached output without probing or invoking a model again',async()=>{
 const {LocalStore}=await import('../packages/sync/src/local-store.ts'),{Hub}=await import('../apps/runner/src/hub.ts'),{Engine}=await import('../apps/runner/src/engine.ts'),{input}=await import('./helpers.ts');
 const dir=await mkdtemp(join(tmpdir(),'neura-runner-artifacts-')),workspaceId=randomUUID(),deviceId=randomUUID(),taskId=randomUUID(),store=new LocalStore(join(dir,'db'),workspaceId),hub=new Hub(store,{dataDir:dir,workspaceId,deviceId,port:0,cloudUrl:null,githubClientId:null,allowFixtures:true}),engine=new Engine(hub);
 engine.adapters.fixture={probeCapabilities:async()=>{throw Error('must not probe');},execute:async()=>{throw Error('must not regenerate');}};
 try{
  await hub.execute({type:'device.register',id:deviceId,name:'test',publicKey:'fixture'});await hub.execute({type:'task.create',id:taskId,input:input()});await hub.execute({type:'task.queue',taskId,expectedVersion:hub.read().tasks[0].version});await hub.execute({type:'run.claim',taskId,runnerId:deviceId},'runner');const run=hub.read().tasks[0].runs[0],lease={taskId,runId:run.id,fencingToken:run.fencingToken};
  await hub.execute({type:'run.reserve',...lease,tokens:1000,calls:1},'runner');await hub.execute({type:'run.settle',...lease,tokens:123,calls:1,costUsd:null},'runner');const runDir=join(dir,'runs',run.id);await mkdir(runDir,{recursive:true});await saveGeneration(runDir,run,'task',output);
  await hub.execute({type:'run.update',...lease,status:'blocked',reason:'invalid_artifact_name'},'runner');await hub.execute({type:'run.release',...lease},'runner');await hub.execute({type:'task.control',taskId,expectedVersion:hub.read().tasks[0].version,action:'resume'});
  const until=Date.now()+5000;while(hub.read().tasks[0].status!=='succeeded'){assert.ok(Date.now()<until,'cached output did not finish');await engine.tick();await new Promise(r=>setTimeout(r,20));}
  const restored=hub.read().tasks[0];assert.equal(restored.artifacts.length,2);assert.equal(restored.runs.length,1);assert.equal(restored.runs[0].tokens,123);assert.equal(restored.runs[0].calls,1);assert.ok(restored.events.some(e=>e.kind==='generation.recovered'));
 }finally{await engine.shutdown();store.close();await rm(dir,{recursive:true,force:true});}
});

test('provider filename grammar has no lookaround and accepts relative paths',()=>{
 assert.ok(!providerArtifactNamePattern.includes('(?='));assert.ok(!providerArtifactNamePattern.includes('(?!'));assert.ok(!providerArtifactNamePattern.includes('(?<'));const pattern=new RegExp(providerArtifactNamePattern);
 for(const name of ['src/test.txt','.github/workflows/check.yml','日本語/報告.md'])assert.ok(pattern.test(name),name);
 for(const name of ['/tmp/x','../x','a/../b','a/./b','a//b','C:/x','a\\b'])assert.equal(pattern.test(name),false,name);
});
