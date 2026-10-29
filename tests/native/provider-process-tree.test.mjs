import {test} from 'node:test';
import assert from 'node:assert/strict';
import {spawn,execFileSync} from 'node:child_process';
import {mkdtemp,readFile,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
const binary=process.env.NEURA_NATIVE_DAEMON;
const delay=ms=>new Promise(r=>setTimeout(r,ms));
async function until(check,ms=8000){const end=Date.now()+ms;while(Date.now()<end){if(await check())return;await delay(25);}throw Error('fixture deadline');}
function alive(pid){try{process.kill(pid,0);return true;}catch(e){if(e.code==='ESRCH')return false;throw e;}}
for(const mode of ['eof','sigterm','parent-crash','detached','exit','fast-group'])test(`native provider-host stops owned descendants: ${mode}`,{skip:!binary,timeout:15000},async()=>{
 const dir=await mkdtemp(join(tmpdir(),'neura-owner-test-'));
 const fixture=join(dir,'fixture'),pidsFile=join(dir,'pids'),writes=join(dir,'writes');
 execFileSync('/usr/bin/cc',['tests/native/fixtures/process-tree.c','-o',fixture]);
 let child,pids=[],stderr='';
 try{
   const args=['provider-host',fixture,pidsFile,writes,mode==='detached'?'detached':mode==='exit'?'exit':mode==='fast-group'?'fast-group':'tree'];
   if(mode==='parent-crash'){
     const source=`const{spawn}=require('node:child_process');const c=spawn(process.argv[1],process.argv.slice(2),{stdio:['pipe','inherit','inherit']});console.log(c.pid);setInterval(()=>{},60000);`;
     child=spawn(process.execPath,['-e',source,binary,...args],{stdio:['pipe','pipe','pipe']});
   }else child=spawn(binary,args,{stdio:['pipe','pipe','pipe']});
   child.stderr.on('data',b=>stderr+=b);
   await until(async()=>{try{pids=(await readFile(pidsFile,'utf8')).trim().split('\n').map(Number);return pids.length===2;}catch{return false;}});
   assert.ok(pids.every(pid=>pid>1&&pid!==process.pid));
   if(mode==='sigterm')child.kill('SIGTERM');
   else if(mode==='parent-crash')child.kill('SIGKILL');
   else if(mode!=='exit'&&mode!=='fast-group')child.stdin.end();
   await until(()=>pids.every(pid=>!alive(pid)));
   if(mode!=='fast-group'){const before=(await readFile(writes)).length;await delay(100);assert.equal((await readFile(writes)).length,before);}
   await until(()=>child.exitCode!==null||child.signalCode!==null);
   assert.equal(stderr,'');
   if(mode==='exit')assert.equal(child.exitCode,7);
 }finally{for(const pid of pids)if(alive(pid))try{process.kill(pid,'SIGKILL');}catch{}if(child&&child.exitCode===null&&child.signalCode===null)child.kill('SIGKILL');await rm(dir,{recursive:true,force:true});}
});
for(const [count,mode]of [[10,'eof'],[20,'parent-crash'],[32,'timeout'],[1,'before-attach']])test(`shared native ownership: ${count} reservations, ${mode}`,{skip:!binary,timeout:20000},async()=>{
 const dir=await mkdtemp(join(tmpdir(),'neura-shared-owner-')),fixture=join(dir,'fixture');
 execFileSync('/usr/bin/cc',['tests/native/fixtures/process-tree.c','-o',fixture]);
 let parent,pids=[],helper,stderr='';
 try{
  parent=spawn(process.execPath,['tests/native/fixtures/process-supervisor-parent.mjs',binary,fixture,dir,String(count),mode],{stdio:['pipe','pipe','pipe']});
  parent.stderr.on('data',b=>stderr+=b);
  await until(async()=>{try{helper=Number(await readFile(dir+'/helper','utf8'));pids=(await Promise.all(Array.from({length:count},(_,i)=>readFile(dir+'/pids-'+i,'utf8')))).flatMap(s=>s.trim().split('\n').map(Number));return pids.length===count*2;}catch{return false;}});
  if(mode==='parent-crash'||mode==='before-attach')parent.kill('SIGKILL');else parent.stdin.write('stop\n');
  await until(()=>pids.every(pid=>!alive(pid))&&!alive(helper));
  const before=await Promise.all(Array.from({length:count},(_,i)=>readFile(dir+'/writes-'+i).then(b=>b.length)));
  await delay(100);assert.deepEqual(await Promise.all(Array.from({length:count},(_,i)=>readFile(dir+'/writes-'+i).then(b=>b.length))),before);
  assert.equal(stderr,'');
 }finally{for(const pid of [...pids,helper,parent?.pid])if(pid>1&&alive(pid))try{process.kill(pid,'SIGKILL');}catch{}await rm(dir,{recursive:true,force:true});}
});
test('shared helper lifetime lock delays ready until old descendants stop; waiting EOF exits',{skip:!binary,timeout:15000},async()=>{
 const {createInterface}=await import('node:readline');
 const dir=await mkdtemp(join(tmpdir(),'neura-supervisor-lock-')),fixture=join(dir,'fixture');
 execFileSync('/usr/bin/cc',['tests/native/fixtures/process-tree.c','-o',fixture]);
 const helpers=[],children=[];let pids=[];
 const start=()=>{const child=spawn(binary,['process-supervisor',dir+'/owner.lock'],{stdio:['pipe','pipe','pipe']}),messages=[];createInterface({input:child.stdout}).on('line',s=>messages.push(JSON.parse(s)));helpers.push(child);return{child,messages,send:value=>child.stdin.write(JSON.stringify(value)+'\n')};};
 try{
  const first=start();first.send({id:'ready',op:'ready'});await until(()=>first.messages.length===1);assert.equal(first.messages[0].ok,true);
  const token=(await import('node:crypto')).randomUUID();first.send({id:'reserve',op:'reserve',token});await until(()=>first.messages.length===2);
  const owned=spawn(fixture,[dir+'/pids',dir+'/writes','detached'],{env:{...process.env,NEURA_PROCESS_OWNER:token},detached:true,stdio:'ignore'});children.push(owned);
  first.send({id:'attach',op:'attach',token,pid:owned.pid});await until(async()=>{try{pids=(await readFile(dir+'/pids','utf8')).trim().split('\n').map(Number);return pids.length===2&&first.messages.length===3;}catch{return false;}});
  const second=start();second.send({id:'ready',op:'ready'});await delay(150);assert.equal(second.messages.length,0);
  const waiter=start();waiter.send({id:'ready',op:'ready'});await delay(100);waiter.child.stdin.end();await until(()=>waiter.child.exitCode!==null);assert.equal(waiter.child.exitCode,0);assert.equal(waiter.messages.length,0);
  first.child.stdin.end();await until(()=>second.messages.length===1);assert.equal(second.messages[0].ok,true);assert.ok(pids.every(pid=>!alive(pid)),'ready follows full descendant cleanup');
  second.child.stdin.end();await until(()=>helpers.every(c=>c.exitCode!==null));
 }finally{for(const pid of [...pids,...helpers.map(c=>c.pid),...children.map(c=>c.pid)])if(pid>1&&alive(pid))try{process.kill(pid,'SIGKILL');}catch{}await rm(dir,{recursive:true,force:true});}
});
