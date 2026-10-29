// Same isolated fixture/binary, with a test-only baseline reproducing the old
// 10ms pump. Reports app-process CPU time and pump timer wakes, not system CPU.
import {createServer} from 'node:http';
import {spawn} from 'node:child_process';
import {mkdtemp,writeFile,readFile} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join,resolve} from 'node:path';
import assert from 'node:assert/strict';
const server=createServer((req,res)=>res.end('<!doctype html><title>Idle pump probe</title><h1>Idle</h1>'));
await new Promise(r=>server.listen(0,'127.0.0.1',r));
const results=[];
try {
 for (const mode of ['fixed10','adaptive','fixed10','adaptive']) {
  const data=await mkdtemp(join(tmpdir(),`neura-pump-${mode}-`));
  await writeFile(join(data,'pump-probe'),'');
  if(mode==='fixed10')await writeFile(join(data,'pump-fixed10'),'');
  const child=spawn(resolve(process.env.NEURA_APP_OUTPUT??'apps/macos/dist/neuraOS.app','Contents/MacOS/NeuraOS'),['--extensions-smoke',`http://127.0.0.1:${server.address().port}/`,data,'44349'],{stdio:'ignore'});
  const timer=setTimeout(()=>child.kill('SIGKILL'),30000);
  try {assert.equal(await new Promise((r,j)=>{child.on('error',j);child.on('exit',r)}),0,'clean probe shutdown');}
  finally {clearTimeout(timer);}
  const result={...JSON.parse(await readFile(join(data,'pump-evidence.json'),'utf8')),data};
  results.push(result);console.log(result);
 }
 console.log(JSON.stringify(results,null,2));
} finally {server.closeAllConnections();server.close();}
