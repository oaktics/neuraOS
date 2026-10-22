import {test} from 'node:test';
import assert from 'node:assert/strict';
import {mkdtemp, mkdir, writeFile, readFile, access, rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {install} from '../../scripts/native/release/update.mjs';

async function fixture(t) {
  const home = await mkdtemp(join(tmpdir(), 'neura-installer-'));
  t.after(() => rm(home, {recursive: true, force: true}));
  const data = join(home, 'Library/Application Support/neuraOS/Updates');
  const stage = join(data, 'stage-test');
  const target = join(home, 'Applications/neuraOS.app');
  const plist = join(home, 'Library/LaunchAgents/app.neuraos.daemon.plist');
  await mkdir(join(stage, 'neuraOS.app'), {recursive: true});
  await mkdir(target, {recursive: true});
  await mkdir(join(home, 'Library/LaunchAgents'), {recursive: true});
  await mkdir(join(data, 'install.lock'));
  await mkdir(join(home, 'Library/Application Support/neuraOS/Developer'));
  await writeFile(join(home, 'Library/Application Support/neuraOS/Developer/daemon-token'), 'test-token');
  await writeFile(join(target, 'version'), 'old');
  await writeFile(join(stage, 'neuraOS.app/version'), 'new');
  await writeFile(plist, 'old-service');
  return {home, data, stage, target, plist};
}
test('successful install replaces app, keeps backup, opens only after health check', async t => {
  const f = await fixture(t), calls = [];
  await install(f.stage, 123, {home: f.home, parentExists: () => false, pause: async () => {},
    execute: async (command, args) => {calls.push([command, args]);},
    request: async () => ({ok: true})});
  assert.equal(await readFile(join(f.target, 'version'), 'utf8'), 'new');
  assert.equal(await readFile(join(f.target + '.previous', 'version'), 'utf8'), 'old');
  assert.equal(calls.at(-1)[0], '/usr/bin/open');
  await assert.rejects(access(join(f.data, 'install.lock')));
});
test('failed daemon health restores app and original LaunchAgent', async t => {
  const f = await fixture(t), calls = [];
  await install(f.stage, 123, {home: f.home, parentExists: () => false, pause: async () => {},
    execute: async (command, args) => {calls.push([command, args]); if (args.at(-1) === 'install') await writeFile(f.plist, 'new-service');},
    request: async () => ({ok: false})});
  assert.equal(await readFile(join(f.target, 'version'), 'utf8'), 'old');
  assert.equal(await readFile(f.plist, 'utf8'), 'old-service');
  assert(calls.some(([, args]) => args[0] === 'bootstrap'));
  assert.match(await readFile(join(f.data, 'last-error.txt'), 'utf8'), /Daemon/);
  await assert.rejects(access(join(f.data, 'install.lock')));
});
test('application refusing to exit leaves app and service untouched', async t => {
  const f = await fixture(t), calls = [];
  await install(f.stage, 123, {home: f.home, parentExists: () => true, pause: async () => {}, execute: async (...args) => {calls.push(args);}});
  assert.equal(await readFile(join(f.target, 'version'), 'utf8'), 'old');
  assert.equal(await readFile(f.plist, 'utf8'), 'old-service');
  assert.equal(calls.length, 0);
  assert.match(await readFile(join(f.data, 'last-error.txt'), 'utf8'), /終了しなかった/);
});
