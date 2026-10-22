import {execFile, spawn} from 'node:child_process';
import {promisify} from 'node:util';
import {readFile, writeFile, mkdir, mkdtemp, rm, rename, copyFile, access} from 'node:fs/promises';
import {join, resolve} from 'node:path';
import {homedir} from 'node:os';
import {createHash} from 'node:crypto';
import {fileURLToPath} from 'node:url';
const exec = promisify(execFile);
export const repository = 'oaktics/neuraOS';
export function validateRelease(release, arch = process.arch) {
  if (release.draft || release.prerelease || !/^native-\d+$/.test(release.tag_name)) throw new Error('対応する正式リリースではありません。');
  const name = `neuraOS-darwin-${arch}.zip`;
  const asset = release.assets?.find(a => a.name === name);
  if (!asset || !/^sha256:[a-f0-9]{64}$/.test(asset.digest ?? '')) throw new Error('このMac用の検証可能な更新ファイルがありません。');
  const expected = `https://github.com/${repository}/releases/download/${release.tag_name}/${name}`;
  if (asset.browser_download_url !== expected) throw new Error('更新ファイルのURLが不正です。');
  return {tag: release.tag_name, build: Number(release.tag_name.slice(7)), name, digest: asset.digest.slice(7), url: expected};
}
export function verifyArchive(bytes, digest) {
  if (createHash('sha256').update(bytes).digest('hex') !== digest) throw new Error('更新ファイルのSHA-256が一致しません。');
}
async function latest() {
  const response = await fetch(`https://api.github.com/repos/${repository}/releases/latest`, {signal: AbortSignal.timeout(30000)});
  if (response.ok) return {...validateRelease(await response.json()), authenticated: false};
  // Private repositories use gh's own credential store. Never persist or print tokens.
  try {
    const {stdout} = await exec('gh', ['api', `repos/${repository}/releases/latest`], {timeout: 30000});
    return {...validateRelease(JSON.parse(stdout)), authenticated: true};
  } catch {throw new Error('更新を取得できません。リリースの公開状況・ネット接続・gh auth loginを確認してください。');}
}
const data = join(homedir(), 'Library/Application Support/neuraOS/Updates');
const target = join(homedir(), 'Applications/neuraOS.app');
const delay = ms => new Promise(r => setTimeout(r, ms));
async function prepare(tag, parentPID) {
  const release = await latest();
  if (release.tag !== tag) throw new Error('新しいリリースが公開されました。もう一度確認してください。');
  if (!Number.isSafeInteger(parentPID) || parentPID <= 1) throw new Error('Invalid application PID');
  await mkdir(data, {recursive: true, mode: 0o700});
  const lock = join(data, 'install.lock');
  try {await mkdir(lock);} catch {throw new Error('更新処理が既に実行中です。');}
  let stage;
  try {
    stage = await mkdtemp(join(data, 'stage-'));
    const archive = join(stage, release.name);
    if (release.authenticated) await exec('gh', ['release', 'download', release.tag, '--repo', repository, '--pattern', release.name, '--dir', stage], {timeout: 600000});
    else {
      const response = await fetch(release.url, {signal: AbortSignal.timeout(600000)});
      if (!response.ok) throw new Error('更新ファイルのダウンロードに失敗しました。');
      await writeFile(archive, Buffer.from(await response.arrayBuffer()));
    }
    verifyArchive(await readFile(archive), release.digest);
    await exec('/usr/bin/ditto', ['-x', '-k', archive, stage]);
    const app = join(stage, 'neuraOS.app');
    await exec('/usr/bin/codesign', ['--verify', '--deep', '--strict', app]);
    const plist = join(app, 'Contents/Info.plist');
    const readPlist = async key => (await exec('/usr/libexec/PlistBuddy', ['-c', `Print :${key}`, plist])).stdout.trim();
    if (await readPlist('CFBundleIdentifier') !== 'app.neuraos.native' || await readPlist('CFBundleVersion') !== String(release.build)) throw new Error('アプリのバージョン情報が一致しません。');
    await access(join(app, 'Contents/Resources/Runtime/bin/node'));
    await copyFile(fileURLToPath(import.meta.url), join(stage, 'install.mjs'));
    // The installer runs outside the app being replaced, including its Node binary.
    await copyFile(process.execPath, join(stage, 'node'));
    const helper = spawn(join(stage, 'node'), [join(stage, 'install.mjs'), 'apply', stage, String(parentPID)], {detached: true, stdio: 'ignore', env: process.env});
    await new Promise((resolve, reject) => {helper.once('spawn', resolve); helper.once('error', reject);});
    helper.unref();
    return {ready: true};
  } catch (error) {
    if (stage) await rm(stage, {recursive: true, force: true});
    await rm(lock, {recursive: true, force: true});
    throw error;
  }
}
export async function install(stage, parentPID, {
  home = homedir(), execute = exec, pause = delay, request = fetch,
  parentExists = pid => {try {process.kill(pid, 0); return true;} catch (error) {if (error.code === 'ESRCH') return false; throw error;}}
} = {}) {
  const target = join(home, 'Applications/neuraOS.app');
  const data = join(home, 'Library/Application Support/neuraOS/Updates');
  const exec = execute, delay = pause, fetch = request;
  const backup = target + '.previous';
  const plist = join(home, 'Library/LaunchAgents/app.neuraos.daemon.plist');
  const domain = `gui/${process.getuid()}`;
  let oldPlist, moved = false, installed = false, serviceChanged = false;
  try {
    let exited = false;
    for (let attempt = 0; attempt < 120; attempt++) {
      if (!parentExists(parentPID)) {exited = true; break;}
      await delay(500);
    }
    if (!exited) throw new Error('アプリが終了しなかったため更新を中止しました。');
    try {oldPlist = await readFile(plist);} catch (error) {if (error.code !== 'ENOENT') throw error;}
    await mkdir(join(home, 'Applications'), {recursive: true});
    await rm(backup, {recursive: true, force: true});
    try {await rename(target, backup); moved = true;} catch (error) {if (error.code !== 'ENOENT') throw error;}
    await rename(join(stage, 'neuraOS.app'), target); installed = true;
    const runtime = join(target, 'Contents/Resources/Runtime');
    serviceChanged = true;
    await exec(join(runtime, 'bin/node'), ['--import', join(runtime, 'node_modules/tsx/dist/loader.mjs'), join(runtime, 'scripts/native/service.ts'), 'install'], {timeout: 30000});
    let healthy = false;
    for (let attempt = 0; attempt < 30; attempt++) {
      try {const token = (await readFile(join(home, 'Library/Application Support/neuraOS/Developer/daemon-token'), 'utf8')).trim(); const response = await fetch('http://127.0.0.1:4318/v1/state', {headers: {Authorization: `Bearer ${token}`}, signal: AbortSignal.timeout(1000)}); if (response.ok) {healthy = true; break;}} catch {}
      await delay(500);
    }
    if (!healthy) throw new Error('更新後のDaemonが起動しませんでした。');
    await rm(join(data, 'last-error.txt'), {force: true});
    await exec('/usr/bin/open', [target]);
  } catch (error) {
    if (serviceChanged) await exec('/bin/launchctl', ['bootout', `${domain}/app.neuraos.daemon`]).catch(() => {});
    if (installed) await rm(target, {recursive: true, force: true});
    if (moved) await rename(backup, target);
    if (serviceChanged && oldPlist) {
      await writeFile(plist, oldPlist, {mode: 0o600});
      await exec('/bin/launchctl', ['bootstrap', domain, plist]).catch(() => {});
    } else if (serviceChanged) await rm(plist, {force: true});
    await writeFile(join(data, 'last-error.txt'), String(error.message), {mode: 0o600});
    if (moved) await exec('/usr/bin/open', [target]).catch(() => {});
  } finally {
    await rm(join(data, 'install.lock'), {recursive: true, force: true});
    await rm(stage, {recursive: true, force: true});
  }
}
if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const [command, arg, pid] = process.argv.slice(2);
    if (command === 'bootstrap') {
      const runtime = resolve(import.meta.dirname, '../../..');
      const bundledNode = join(runtime, 'bin/node');
      await access(bundledNode);
      const service = ['--import', join(runtime, 'node_modules/tsx/dist/loader.mjs'), join(runtime, 'scripts/native/service.ts')];
      try {await exec(bundledNode, [...service, 'status']);}
      catch {await exec(bundledNode, [...service, 'install'], {timeout: 30000});}
    } else if (command === 'check') console.log(JSON.stringify(await latest()));
    else if (command === 'prepare') console.log(JSON.stringify(await prepare(arg, Number(pid))));
    else if (command === 'apply') await install(arg, Number(pid));
    else throw new Error('Unknown update command');
  } catch (error) {console.error(error.message); process.exitCode = 1;}
}
