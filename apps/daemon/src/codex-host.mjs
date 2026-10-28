// Own the App Server process group and stop it if the neuraOS daemon disappears.
// Unix-socket App Servers otherwise outlive the daemon that created them.
import {spawn,execFile} from 'node:child_process';
import {promisify} from 'node:util';
const [program,...args]=process.argv.slice(2);
if(!program)process.exit(2);
const groups=new Set([process.pid]);
let stopping=false,collecting=false;
async function collect(){
  const {stdout}=await promisify(execFile)('/bin/ps',['-axo','pid=,ppid=,pgid='],{timeout:1000,maxBuffer:8*1024*1024});
  const rows=stdout.trim().split('\n').map(line=>line.trim().split(/\s+/).map(Number)).filter(row=>row.length===3&&row.every(Number.isSafeInteger));
  const owned=new Set(rows.filter(row=>groups.has(row[2])).map(row=>row[0]));
  let changed=true;while(changed){changed=false;for(const [pid,parent,group] of rows)if(owned.has(parent)&&!owned.has(pid)){owned.add(pid);if(group>0)groups.add(group);changed=true;}}
}
function signalAll(signal){for(const group of [...groups].sort((a,b)=>Number(a===process.pid)-Number(b===process.pid)))if(group>0)try{process.kill(-group,signal);}catch(error){if(error.code!=='ESRCH')process.stderr.write('Could not stop a Codex process group.\n');}}
async function stop(){
  if(stopping)return;stopping=true;
  clearInterval(observer);
  try{await collect();}catch{}
  // Catching SIGTERM keeps this owner alive long enough to escalate stubborn descendants.
  const escalation=setTimeout(()=>signalAll('SIGKILL'),1500);
  signalAll('SIGTERM');
  // Keep escalation referenced even after both the child and stdin have closed.
  escalation.ref();
}
process.on('SIGTERM',()=>{void stop();});process.on('SIGHUP',()=>{void stop();});process.on('SIGINT',()=>{void stop();});
process.stdin.on('end',()=>{void stop();});process.stdin.on('error',()=>{void stop();});process.stdin.resume();
const observer=setInterval(()=>{if(collecting||stopping)return;collecting=true;void collect().catch(()=>{}).finally(()=>{collecting=false;});},250);
const child=spawn(program,args,{stdio:['ignore','inherit','inherit']});
child.on('error',()=>{void stop();});child.on('exit',()=>{void stop();});
