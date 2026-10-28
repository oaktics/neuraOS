// This process exclusively owns the daemon's stdin pipe. The setup script must
// never inherit it, so daemon SIGKILL/crash reliably produces EOF here.
import {spawn} from 'node:child_process';
const script=process.argv[2];
if(!script)process.exit(2);
let stopping=false;
const child=spawn('/bin/bash',[script],{detached:true,stdio:['ignore','inherit','inherit']});
function killGroup(){
  // An unsuccessful spawn has no PID. Never signal PGID 0 or our own group.
  if(child.pid>1)try{process.kill(-child.pid,'SIGKILL');}catch(error){
    if(error.code!=='ESRCH')throw error;
  }
}
function stop(){stopping=true;killGroup();}
process.stdin.on('end',stop);process.stdin.on('error',stop);process.stdin.resume();
process.on('SIGTERM',stop);process.on('SIGINT',stop);process.on('SIGHUP',stop);
child.on('error',()=>process.exit(1));
child.on('exit',code=>{
  // Also remove background jobs on success/failure; inherited output handles
  // must not keep runSetup pending after the script has finished.
  killGroup();
  process.exit(stopping?1:(code??1));
});
