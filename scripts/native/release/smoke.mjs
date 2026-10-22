import {mkdtemp, readFile, rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join, resolve} from 'node:path';
import {spawn} from 'node:child_process';
import {once} from 'node:events';
const runtime = resolve('apps/macos/dist/neuraOS.app/Contents/Resources/Runtime');
const data = await mkdtemp(join(tmpdir(), 'neura-release-'));
// Port 0 lets the OS choose an unused port. In-process test exercises packaged
// imports, SQLite and a real native PTY without touching the user's LaunchAgent.
const source = `
import {createDaemon} from './apps/daemon/src/server.ts';
import * as pty from 'node-pty';
import {readFile} from 'node:fs/promises';
const {app}=await createDaemon(process.env.NEURA_DEV_DATA_DIR);
try {
 const address=await app.listen({host:'127.0.0.1',port:0});
 const token=(await readFile(process.env.NEURA_DEV_DATA_DIR+'/daemon-token','utf8')).trim();
 const response=await fetch(address+'/v1/state',{headers:{Authorization:'Bearer '+token}});
 if(!response.ok)throw new Error('Packaged daemon health check failed');
 await new Promise((resolve,reject)=>{
  const term=pty.spawn('/bin/echo',['neura-release-ok'],{name:'xterm',cols:80,rows:24,env:process.env});
  let output='';term.onData(x=>output+=x);
  term.onExit(({exitCode})=>exitCode===0&&output.includes('neura-release-ok')?resolve():reject(new Error('Packaged PTY failed')));
 });
} finally {await app.close();}
`;
try {
  const child = spawn(join(runtime, 'bin/node'), ['--import', join(runtime, 'node_modules/tsx/dist/loader.mjs'), '--input-type=module', '-e', source], {cwd: runtime, env: {...process.env, NEURA_DEV_DATA_DIR: data}, stdio: 'inherit'});
  const timeout = setTimeout(() => child.kill('SIGKILL'), 30000);
  try {const [code] = await once(child, 'exit'); if (code !== 0) throw new Error(`Packaged runtime smoke failed: ${code}`);} finally {clearTimeout(timeout);}
} finally {await rm(data, {recursive: true, force: true});}
