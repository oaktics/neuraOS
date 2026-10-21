import pg from 'pg';
import { cloudServer } from './server.ts';
import { PostgresStore } from './store.ts';
import { S3BlobStore } from '../../../packages/sync/src/storage.ts';
import { randomUUID } from 'node:crypto';
import { ensure } from '../../../packages/policy/src/index.ts';
const required=(name:string)=>{const value=process.env[name];ensure(value,'configuration_missing',name);return value;};
const pool=new pg.Pool({connectionString:required('DATABASE_URL'),max:10});
const roles=await pool.query('SELECT rolsuper,rolbypassrls FROM pg_roles WHERE rolname=current_user');ensure(!roles.rows[0].rolsuper&&!roles.rows[0].rolbypassrls,'unsafe_database_role');
const store=new PostgresStore(pool);
const app=cloudServer(store,new S3BlobStore(required('NEURA_S3_ENDPOINT'),required('NEURA_STORAGE_BUCKET'),required('NEURA_S3_ACCESS_KEY_ID'),required('NEURA_S3_SECRET_ACCESS_KEY')),{allowedGitHubIds:required('NEURA_ALLOWED_GITHUB_IDS').split(',')});
await app.listen({host:process.env.NEURA_CLOUD_HOST??'127.0.0.1',port:Number(process.env.NEURA_CLOUD_PORT??4318)});
let ticking=false;
const scheduleTimer=setInterval(async()=>{
  if(ticking||!process.env.NEURA_SCHEDULER_WORKSPACE||!process.env.NEURA_SCHEDULER_OWNER)return;ticking=true;
  try{await store.apply(process.env.NEURA_SCHEDULER_WORKSPACE,process.env.NEURA_SCHEDULER_OWNER,{operationId:randomUUID(),command:{type:'schedule.tick'}},{id:'cloud-scheduler',role:'scheduler'});}catch{process.stderr.write('scheduler_tick_failed\n');}finally{ticking=false;}
},5000);
for(const signal of ['SIGINT','SIGTERM'] as const)process.once(signal,async()=>{clearInterval(scheduleTimer);await app.close();await pool.end();});
