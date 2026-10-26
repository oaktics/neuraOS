import {mkdtemp, rm, mkdir, cp, readFile} from 'node:fs/promises';
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
  const sleepPlist = join(original, 'Library/LaunchDaemons/app.neuraos.native.sleep.plist');
  const sleepConfig = JSON.parse(execFileSync('/usr/bin/plutil', ['-convert', 'json', '-o', '-', sleepPlist], {encoding: 'utf8'}));
  if (sleepConfig.BundleProgram !== 'Contents/MacOS/NeuraSleepService' ||
      sleepConfig.MachServices?.['app.neuraos.native.sleep'] !== true ||
      sleepConfig.KeepAlive?.SuccessfulExit !== false) throw new Error('Invalid packaged sleep service');
  const sleepExecutable = resolve(original, '..', sleepConfig.BundleProgram);
  execFileSync('/usr/bin/codesign', ['--verify', '--strict', sleepExecutable]);
  // Verify the packaged service fails closed without root. Never register it or
  // change system power settings in CI/smoke tests.
  let sleepStatus;
  try {execFileSync(sleepExecutable, [], {timeout: 5000, stdio: 'pipe'});}
  catch (error) {sleepStatus = error.status;}
  if (sleepStatus !== 77) throw new Error(`Sleep service must reject unprivileged launch: ${sleepStatus}`);

  await cp(join(original, 'MacOS/NeuraOS'), join(app, 'Contents/MacOS/NeuraOS'));
  await cp(join(original, 'Info.plist'), join(app, 'Contents/Info.plist'));
  await cp(join(original, 'Resources/NeuraOS_NeuraOS.bundle'), join(app, 'Contents/Resources/NeuraOS_NeuraOS.bundle'), {recursive: true});
  const executable = join(app, 'Contents/MacOS/NeuraOS');
  execFileSync(executable, ['--check-bundled-resources'], {stdio: 'inherit', timeout: 15000});
  // A unique bundle ID isolates UserDefaults; explicit endpoints isolate app data and services.
  const plist = join(app, 'Contents/Info.plist');
  for (const [key, value] of [['CFBundleIdentifier', 'com.neuraos.reliability-smoke.' + process.pid], ['NeuraDataDirectory', data], ['NeuraEndpoint', 'http://127.0.0.1:1']]) {
    execFileSync('/usr/bin/plutil', ['-replace', key, '-string', value, plist]);
  }
  await cp(join(original, 'Frameworks'), join(app, 'Contents/Frameworks'), {recursive: true, verbatimSymlinks: true});
  execFileSync('codesign', ['--force', '--deep', '--sign', '-', app], {stdio: 'inherit'});
  const report = join(data, 'diagnostic-report.json');
  // Run the actual event pump. AX performPress alone misses native modal click routing bugs.
  const ui = spawn(executable, ['--reliability-smoke', report, '--with-chromium'], {stdio: 'inherit', detached: true});
  const stopUI = () => {if (ui.pid) {try {process.kill(-ui.pid, 'SIGKILL');} catch {ui.kill('SIGKILL');}}};
  const uiTimeout = setTimeout(stopUI, 30000);
  try {const [code] = await once(ui, 'exit'); if (code !== 0) throw new Error(`Packaged modal/UI smoke failed: ${code}`);}
  finally {clearTimeout(uiTimeout); stopUI();}
  const diagnostic = JSON.parse(await readFile(report, 'utf8'));
  if (diagnostic.schemaVersion !== 1 || !diagnostic.logs['app.jsonl']?.includes('report.saved')) throw new Error('Packaged diagnostic export failed');
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
