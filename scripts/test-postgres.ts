import { execFile,spawn } from 'node:child_process';
import { promisify } from 'node:util';
import { readFile } from 'node:fs/promises';
import { randomUUID } from 'node:crypto';
import pg from 'pg';
const exec=promisify(execFile);const name=`neuraos-test-${randomUUID().slice(0,8)}`;
try{
  await exec('docker',['run','-d','--rm','--name',name,'-e','POSTGRES_PASSWORD=fixture-test-only','-p','127.0.0.1::5432','postgres:17-alpine']);
  const {stdout}=await exec('docker',['port',name,'5432']);const port=stdout.trim().split(':').at(-1);const adminUrl=`postgres://postgres:fixture-test-only@127.0.0.1:${port}/postgres`;
  const admin=new pg.Pool({connectionString:adminUrl});let ready=false;
  for(let i=0;i<40;i++){try{await admin.query('SELECT 1');ready=true;break;}catch{await new Promise(r=>setTimeout(r,250));}}
  if(!ready)throw new Error('test_postgres_not_ready');
  await admin.query(await readFile('database/migrations/001_core.sql','utf8'));await admin.query("CREATE ROLE neura_test LOGIN PASSWORD 'fixture-app-only' NOSUPERUSER NOBYPASSRLS");await admin.query('GRANT USAGE ON SCHEMA public TO neura_test; GRANT SELECT,INSERT,UPDATE,DELETE ON ALL TABLES IN SCHEMA public TO neura_test;');await admin.end();
  const child=spawn(process.execPath,['--import','tsx','--test','tests/postgres.test.ts'],{stdio:'inherit',env:{...process.env,NEURA_TEST_DATABASE_URL:`postgres://neura_test:fixture-app-only@127.0.0.1:${port}/postgres`}});
  const code=await new Promise<number|null>((resolve,reject)=>{child.on('exit',resolve);child.on('error',reject);});if(code!==0)process.exitCode=code??1;
}finally{await exec('docker',['rm','-f',name]).catch(()=>{});}
