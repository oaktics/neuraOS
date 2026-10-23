import {createServer} from 'node:http';
import {spawn} from 'node:child_process';
import {mkdtemp,rm,readFile} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {resolve,join} from 'node:path';
const data=await mkdtemp(join(tmpdir(),'neura-chromium-smoke-'));
const server=createServer((request,response)=>{
  response.setHeader('Content-Type','text/html; charset=utf-8');
  if(request.url==='/popup')response.end(`<script>document.title=window.opener?'neura-popup:opener-ok':'missing-opener';</script>`);
  else if(request.url==='/second')response.end('<script>document.title="neura-second";</script>');
  else response.end(`<button style="position:absolute;left:0;top:0;width:200px;height:60px" onclick="window.open('/popup','test')">Open popup</button><script>
    let valid=true;
    if(!sessionStorage.checked){
      const expected=new URL(location.href).searchParams.get('expect')==='1';
      valid=Boolean(localStorage.marker)===expected && document.cookie.includes('neuraSmoke=1')===expected;
      localStorage.marker='1';document.cookie='neuraSmoke=1; Path=/; Max-Age=86400';sessionStorage.checked='1';
    }
    document.title=valid?'neura-main:'+(navigator.userAgent.match(/Chrome\\/[0-9.]+/)||['wrong-engine'])[0]:'storage-failed';
  </script>`);
});
try {
  await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
  const executable=resolve(process.env.NEURA_APP_OUTPUT??'apps/macos/dist/neuraOS.app','Contents/MacOS/NeuraOS');
  // Reopen the same profile to verify cookies/storage and release of profile locks.
  for(const expected of [0,1]) {
    const child=spawn(executable,['--chromium-smoke',`http://127.0.0.1:${server.address().port}/?expect=${expected}`,data],{stdio:'inherit',detached:true});
    const timer=setTimeout(()=>{try{process.kill(-child.pid,'SIGKILL');}catch{}},40000);
    let code;
    try {code=await new Promise((resolve,reject)=>{child.once('error',reject);child.once('exit',(code,signal)=>{if(signal)console.error('Chromium exited with signal',signal);resolve(code);});});}
    finally {clearTimeout(timer);}
    if(code!==0){
      console.error(await readFile(join(data,'Chromium/chromium.log'),'utf8').catch(()=>''));
      throw new Error(`Chromium integration check failed (${code})`);
    }
  }
  console.log('Chromium rendering, history, popup opener, persistent storage and clean restart passed.');
} finally {server.closeAllConnections();await new Promise(resolve=>server.close(resolve));await rm(data,{recursive:true,force:true,maxRetries:10,retryDelay:100});}
