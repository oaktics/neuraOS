import { mkdir, readFile, writeFile, unlink, open } from 'node:fs/promises';
import { resolve, join } from 'node:path';
import { randomBytes, randomUUID } from 'node:crypto';
import { LocalStore } from '../../../packages/sync/src/local-store.ts';
import { Hub, type RunnerConfig } from './hub.ts';
import { Engine } from './engine.ts';
import { runnerServer } from './server.ts';
import { log } from '../../../packages/observability/src/index.ts';
const dataDir=resolve(process.env.NEURA_DATA_DIR??'.data');await mkdir(dataDir,{recursive:true,mode:0o700});
const lockPath=join(dataDir,'runner.lock');
try{const lock=await open(lockPath,'wx',0o600);await lock.writeFile(String(process.pid));await lock.close();}catch(error){
  if((error as NodeJS.ErrnoException).code!=='EEXIST')throw error;
  const pid=Number(await readFile(lockPath,'utf8'));let alive=false;try{process.kill(pid,0);alive=true;}catch{}
  if(alive)throw new Error('Runner is already active');await unlink(lockPath);const lock=await open(lockPath,'wx',0o600);await lock.writeFile(String(process.pid));await lock.close();
}
const load=async(name:string,fallback:string)=>{try{return (await readFile(join(dataDir,name),'utf8')).trim();}catch{await writeFile(join(dataDir,name),fallback,{mode:0o600,flag:'wx'});return fallback;}};
const localWorkspace=await load('workspace-id',randomUUID());const deviceId=await load('device-id',randomUUID());const token=await load('runner-token',randomBytes(32).toString('hex'));
let disk:Partial<RunnerConfig>={};try{disk=JSON.parse(await readFile(join(dataDir,'cloud-config.json'),'utf8'));}catch{}
const config:RunnerConfig={dataDir,deviceId,workspaceId:process.env.NEURA_WORKSPACE_ID??disk.workspaceId??localWorkspace,port:Number(process.env.NEURA_RUNNER_PORT??4317),cloudUrl:process.env.NEURA_CLOUD_URL??disk.cloudUrl??null,githubClientId:process.env.NEURA_GITHUB_CLIENT_ID??disk.githubClientId??null,allowFixtures:process.env.NEURA_ALLOW_FIXTURES==='1'};
const store=new LocalStore(join(dataDir,config.cloudUrl?`cloud-${config.workspaceId}.sqlite`:'runner.sqlite'),config.workspaceId);const hub=new Hub(store,config);
if(!config.cloudUrl&&!store.read().devices.some(d=>d.id===deviceId))await hub.execute({type:'device.register',id:deviceId,name:'このMac',publicKey:'local-development-no-cloud-identity'});
const engine=new Engine(hub);const app=runnerServer(hub,engine,token);
await app.listen({host:'127.0.0.1',port:config.port});
log('runner.started',{mode:config.cloudUrl?'cloud':'local'});
const interval=setInterval(()=>void engine.tick().catch(()=>log('runner.tick.failed',{code:'tick_failed'})),1500);void engine.tick();
let closing=false;for(const signal of ['SIGINT','SIGTERM'] as const)process.once(signal,async()=>{if(closing)return;closing=true;clearInterval(interval);await engine.shutdown();await app.close();store.close();await unlink(lockPath).catch(()=>{});});
