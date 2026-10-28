import {mkdtemp, cp, rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join, resolve} from 'node:path';
import {fileURLToPath} from 'node:url';
import {spawn} from 'node:child_process';
import {once} from 'node:events';

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

export async function smokeRuntime(original) {
  // A bundle inside the checkout can accidentally resolve missing dependencies
  // from the checkout's node_modules. Relocate the complete runtime first.
  const temporary = await mkdtemp(join(tmpdir(), 'neura-runtime-'));
  try {
    const runtime = join(temporary, 'Runtime');
    await cp(original, runtime, {recursive: true, verbatimSymlinks: true});
    const env = {...process.env, NEURA_DEV_DATA_DIR: join(temporary, 'data')};
    delete env.NODE_PATH;
    delete env.NODE_OPTIONS;
    const child = spawn(join(runtime, 'bin/node'), ['--import', join(runtime, 'node_modules/tsx/dist/loader.mjs'), '--input-type=module', '-e', source], {cwd: runtime, env, stdio: 'inherit'});
    const timeout = setTimeout(() => child.kill('SIGKILL'), 30000);
    try {
      const [code] = await once(child, 'exit');
      if (code !== 0) throw new Error(`Packaged runtime smoke failed: ${code}`);
    } finally {clearTimeout(timeout);}
    console.log('Relocated packaged runtime: daemon, SQLite and PTY passed.');
  } finally {await rm(temporary, {recursive: true, force: true});}
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  await smokeRuntime(resolve(process.env.NEURA_APP_OUTPUT ?? 'apps/macos/dist/neuraOS.app', 'Contents/Resources/Runtime'));
}
