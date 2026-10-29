import {signApplication, selectIdentity} from '../signing/sign.mjs';
import {cp, mkdir, readFile, realpath, readdir, symlink, rm, copyFile, writeFile, chmod} from 'node:fs/promises';
import {createHash} from 'node:crypto';
import {join, resolve, dirname, relative} from 'node:path';
import {execFileSync} from 'node:child_process';

// Copy the installed, lockfile-resolved dependency graph, including native addons.
// No registry resolution or install scripts run during packaging or installation.
const root = resolve(import.meta.dirname, '../../..');
const signingIdentity = selectIdentity();
const app = resolve(process.env.NEURA_APP_OUTPUT ?? join(root, 'apps/macos/dist/neuraOS.app'));
const runtime = join(app, 'Contents/Resources/Runtime');
await rm(runtime, {recursive: true, force: true});
await mkdir(join(runtime, 'bin'), {recursive: true});
await copyFile(process.execPath, join(runtime, 'bin/node'));
await copyFile(resolve(dirname(process.execPath), '../LICENSE'), join(runtime, 'NODE-LICENSE'));
await cp(join(root, 'apps/daemon'), join(runtime, 'apps/daemon'), {recursive: true});
await cp(join(root, 'scripts/native'), join(runtime, 'scripts/native'), {recursive: true});
await writeFile(join(runtime, 'package.json'), JSON.stringify({private: true, type: 'module'}));
const copied = new Map();
async function locate(name, from) {
  for (let path = from; ; path = dirname(path)) {
    try {return await realpath(join(path, 'node_modules', name));} catch (error) {if (error.code !== 'ENOENT') throw error;}
    if (dirname(path) === path) throw new Error(`Missing dependency: ${name}`);
  }
}
async function copyPackage(source) {
  if (copied.has(source)) return copied.get(source);
  const destination = join(runtime, 'node_modules/.store', createHash('sha256').update(relative(root, source)).digest('hex').slice(0, 24));
  copied.set(source, destination);
  await cp(source, destination, {recursive: true, filter: path => path === source || !relative(source, path).split('/').includes('node_modules')});
  const manifest = JSON.parse(await readFile(join(source, 'package.json'), 'utf8'));
  for (const name of new Set([...Object.keys(manifest.dependencies ?? {}), ...Object.keys(manifest.optionalDependencies ?? {})])) {
    let child;
    try {child = await locate(name, source);} catch (error) {if (manifest.optionalDependencies?.[name]) continue; throw error;}
    const target = await copyPackage(child), link = join(destination, 'node_modules', name);
    await mkdir(dirname(link), {recursive: true});
    await symlink(relative(dirname(link), target), link);
  }
  return destination;
}
const manifest = JSON.parse(await readFile(join(root, 'package.json'), 'utf8'));
for (const name of new Set([...Object.keys(manifest.dependencies ?? {}), 'tsx'])) {
  const target = await copyPackage(await locate(name, root)), link = join(runtime, 'node_modules', name);
  await mkdir(dirname(link), {recursive: true});
  await symlink(relative(dirname(link), target), link);
}
const ptyRoot = await realpath(join(runtime, 'node_modules/node-pty'));
for (const folder of [`prebuilds/darwin-${process.arch}`, 'build/Release']) {
  await chmod(join(ptyRoot, folder, 'spawn-helper'), 0o755).catch(error => {if (error.code !== 'ENOENT') throw error;});
}
// Sign nested Mach-O binaries before the enclosing application.
async function signTree(path) {
  for (const entry of await readdir(path, {withFileTypes: true})) {
    const file = join(path, entry.name);
    if (entry.isDirectory()) await signTree(file);
    else if (entry.isFile() && (entry.name.endsWith('.node') || entry.name === 'node' || entry.name === 'spawn-helper' || entry.name === 'esbuild' || entry.name === 'claude')) {
      if (execFileSync('/usr/bin/file', ['-b', file], {encoding: 'utf8'}).includes('Mach-O'))
        execFileSync('codesign', ['--force', '--sign', '-', file], {stdio: 'inherit'});
    }
  }
}
if (signingIdentity === '-') await signTree(runtime);
signApplication(app, signingIdentity);
execFileSync('codesign', ['--verify', '--deep', '--strict', app], {stdio: 'inherit'});
console.log(app);
