import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp,writeFile,rm,mkdir } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnIsolated,runNodeTest } from '../packages/execution/src/sandbox.ts';
import { inferenceProxy } from '../packages/adapters/proxy.ts';
test('macOS sandbox denies reading a canary outside the execution root and external network', {skip:process.platform!=='darwin'},async()=>{
  const dir=await mkdtemp(join(tmpdir(),'neura-sandbox-'));const runtime=join(dir,'runtime');await mkdir(runtime);const secret=join(dir,'secret');await writeFile(secret,'CANARY_NOT_A_REAL_SECRET');
  const script=`const fs=require('fs');let denied=false;try{fs.readFileSync(${JSON.stringify(secret)},'utf8')}catch(e){denied=e.code==='EPERM'||e.code==='EACCES'};fs.writeFileSync('allowed.txt','ok');if(!denied)process.exit(3);const net=require('net');const s=net.connect(9,'127.0.0.1');s.on('connect',()=>process.exit(4));s.on('error',e=>{if(e.code!=='EPERM'&&e.code!=='EACCES')process.exit(5);console.log('isolated');});`;
  try{const child=await spawnIsolated(process.execPath,['-e',script],runtime,32123,{PATH:'/usr/bin:/bin',HOME:runtime,TMPDIR:runtime});let out='',err='';child.stdout.on('data',b=>out+=b);child.stderr.on('data',b=>err+=b);const code=await new Promise<number|null>((resolve,reject)=>{child.on('error',reject);child.on('exit',resolve);});assert.equal(code,0,err);assert.match(out,/isolated/);}finally{await rm(dir,{recursive:true,force:true});}
});
test('inference proxy refuses unrelated services, paths, query strings and methods',async()=>{const proxy=await inferenceProxy('codex','FAKE_TEST_KEY');try{for(const [path,method] of [['/v1/files','POST'],['/v1/responses?url=https://attacker.example','POST'],['/v1/responses','DELETE'],['/','GET']]){assert.equal((await fetch(proxy.url+path,{method})).status,403);}}finally{await proxy.close();}});
test('Docker verifies generated code with no network and no writable host mount',{skip:process.env.NEURA_TEST_DOCKER!=='1'},async()=>{const dir=await mkdtemp(join(tmpdir(),'neura-container-'));try{const result=await runNodeTest('export const value=42;','import assert from "node:assert/strict"; import fs from "node:fs"; import {value} from "./artifact.mjs"; assert.equal(value,42); assert.throws(()=>fs.writeFileSync("/work/escape","bad"));',dir,new AbortController().signal);assert.equal(result.passed,true,result.evidence);}finally{await rm(dir,{recursive:true,force:true});}});
