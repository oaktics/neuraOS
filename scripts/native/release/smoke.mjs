import {smokeRuntime} from './runtime-smoke.mjs';
import {mkdtemp, rm, mkdir, cp, readFile, writeFile, access} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join, resolve} from 'node:path';
import {spawn, spawnSync, execFileSync} from 'node:child_process';
import {once} from 'node:events';
const runtime = resolve(process.env.NEURA_APP_OUTPUT ?? 'apps/macos/dist/neuraOS.app', 'Contents/Resources/Runtime');
const data = await mkdtemp(join(tmpdir(), 'neura-release-'));
let completed = false;
try {
  await smokeRuntime(runtime);
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
  // Static checks remain mandatory even on CI images with SIP disabled, where
  // the OS deliberately bypasses Hardened Runtime enforcement.
  for (const peer of [join(original, 'MacOS/NeuraOS'), sleepExecutable, join(runtime,'bin/neura-native-core'), join(runtime,'bin/neura-updater')]) {
    const signature = spawnSync('/usr/bin/codesign', ['-d', '--verbose=4', peer], {encoding: 'utf8'});
    const flags = /flags=0x([a-f0-9]+)/i.exec(signature.stderr ?? '')?.[1];
    if (signature.status !== 0 || !flags || !(parseInt(flags, 16) & 0x10000)) throw new Error('Missing Hardened Runtime: ' + peer);
    const xml = execFileSync('/usr/bin/codesign', ['-d', '--entitlements', ':-', peer], {encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe']});
    const entitlements = xml.trim() ? JSON.parse(execFileSync('/usr/bin/plutil', ['-convert', 'json', '-o', '-', '-'], {input: xml, encoding: 'utf8'})) : {};
    for (const key of ['com.apple.security.cs.allow-dyld-environment-variables', 'com.apple.security.get-task-allow',
      'com.apple.security.cs.allow-unsigned-executable-memory', 'com.apple.security.cs.disable-executable-page-protection']) {
      if (entitlements[key] === true) throw new Error('Unsafe peer entitlement: ' + key);
    }
    if (peer === sleepExecutable && entitlements['com.apple.security.cs.disable-library-validation'] === true) throw new Error('Sleep daemon must retain library validation');
  }

  // Prove the reported injection path is blocked on the actual packaged client.
  // The unhardened control must load the same test dylib, avoiding a vacuous pass.
  const probeSource = join(data, 'injection.c'), controlSource = join(data, 'control.c');
  const probe = join(data, 'injection.dylib'), control = join(data, 'control'), marker = join(data, 'injected');
  await writeFile(probeSource, '#include <stdio.h>\n#include <stdlib.h>\n__attribute__((constructor)) static void probe(void) {const char *p=getenv("NEURA_INJECTION_MARKER");if(p){FILE*f=fopen(p,"w");if(f){fputs("injected",f);fclose(f);}}}\n');
  await writeFile(controlSource, 'int main(void) {return 0;}\n');
  execFileSync('xcrun', ['clang', '-dynamiclib', probeSource, '-o', probe]);
  execFileSync('xcrun', ['clang', controlSource, '-o', control]);
  const injectionEnv = {...process.env, DYLD_INSERT_LIBRARIES: probe, NEURA_INJECTION_MARKER: marker};
  execFileSync(control, [], {env: injectionEnv, timeout: 5000});
  await access(marker);
  await rm(marker);
  execFileSync(join(original, 'MacOS/NeuraOS'), ['--check-bundled-resources'], {env: injectionEnv, timeout: 15000});
  let injected = false;
  try {await access(marker); injected = true;} catch (error) {if (error.code !== 'ENOENT') throw error;}
  const sip = execFileSync('/usr/bin/csrutil', ['status'], {encoding: 'utf8'}).trim();
  console.log(sip);
  if (injected) {
    if (sip !== 'System Integrity Protection status: disabled.') throw new Error('Packaged client allowed DYLD injection');
    console.log('SKIP runtime injection enforcement: SIP is disabled on this host; peer signing/entitlement checks passed.');
  } else {console.log('Packaged client rejected DYLD injection; unhardened positive control executed it.');}

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
  const uiTimeout = setTimeout(() => {
    spawnSync('/usr/bin/sample', [String(ui.pid), '1', '-file', join(data, 'ui-timeout.sample.txt')], {timeout: 5000});
    stopUI();
  }, 30000);
  try {const [code, signal] = await once(ui, 'exit'); if (code !== 0) throw new Error(`Packaged modal/UI smoke failed: code=${code} signal=${signal}; evidence=${data}`);}
  finally {clearTimeout(uiTimeout); stopUI();}
  const diagnostic = JSON.parse(await readFile(report, 'utf8'));
  if (diagnostic.schemaVersion !== 1 || !diagnostic.logs['app.jsonl']?.includes('report.saved')) throw new Error('Packaged diagnostic export failed');
  await rm(join(app, 'Contents/Resources/NeuraOS_NeuraOS.bundle'), {recursive: true});
  let missingStatus, missingMessage;
  try {execFileSync(executable, ['--check-bundled-resources'], {timeout: 15000, stdio: 'pipe'});}
  catch (error) {missingStatus = error.status; missingMessage = error.stderr?.toString();}
  if (missingStatus !== 1 || !missingMessage?.includes('Missing GitHub Markdown resources'))
    throw new Error(`Missing resources must fail cleanly, got status ${missingStatus}`);
  completed = true;
} finally {
  if (completed) await rm(data, {recursive: true, force: true});
  else console.error(`Release smoke failure evidence retained: ${data}`);
}
