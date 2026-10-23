import {mkdtemp, rm, mkdir, cp} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join, resolve} from 'node:path';
import {spawn, execFileSync} from 'node:child_process';
import {once} from 'node:events';
const runtime = resolve(process.env.NEURA_APP_OUTPUT ?? 'apps/macos/dist/neuraOS.app', 'Contents/Resources/Runtime');
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
  // Tests against .build can silently find SwiftPM resources at their original
  // build path. Run the packaged executable from a relocated app as well, then
  // remove its resources to verify it cannot fall back to the build machine.
  const app = join(data, 'neuraOS.app');
  await mkdir(join(app, 'Contents/MacOS'), {recursive: true});
  const original = resolve(runtime, '../..');
  await cp(join(original, 'MacOS/NeuraOS'), join(app, 'Contents/MacOS/NeuraOS'));
  await cp(join(original, 'Info.plist'), join(app, 'Contents/Info.plist'));
  await cp(join(original, 'Resources/NeuraOS_NeuraOS.bundle'), join(app, 'Contents/Resources/NeuraOS_NeuraOS.bundle'), {recursive: true});
  const executable = join(app, 'Contents/MacOS/NeuraOS');
  execFileSync(executable, ['--check-bundled-resources'], {stdio: 'inherit', timeout: 15000});
  await rm(join(app, 'Contents/Resources/NeuraOS_NeuraOS.bundle'), {recursive: true});
  let missingStatus, missingMessage;
  try {execFileSync(executable, ['--check-bundled-resources'], {timeout: 15000, stdio: 'pipe'});}
  catch (error) {missingStatus = error.status; missingMessage = error.stderr?.toString();}
  if (missingStatus !== 1 || !missingMessage?.includes('Missing GitHub Markdown resources'))
    throw new Error(`Missing resources must fail cleanly, got status ${missingStatus}`);

  const child = spawn(join(runtime, 'bin/node'), ['--import', join(runtime, 'node_modules/tsx/dist/loader.mjs'), '--input-type=module', '-e', source], {cwd: runtime, env: {...process.env, NEURA_DEV_DATA_DIR: data}, stdio: 'inherit'});
  const timeout = setTimeout(() => child.kill('SIGKILL'), 30000);
  try {const [code] = await once(child, 'exit'); if (code !== 0) throw new Error(`Packaged runtime smoke failed: ${code}`);} finally {clearTimeout(timeout);}
} finally {await rm(data, {recursive: true, force: true});}
