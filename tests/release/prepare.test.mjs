import {test} from 'node:test';
import assert from 'node:assert/strict';
import {execFile} from 'node:child_process';
import {promisify} from 'node:util';
import {mkdtemp, mkdir, writeFile, readFile, readdir, rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {createHash} from 'node:crypto';
import {prepare} from '../../scripts/native/release/update.mjs';

const exec = promisify(execFile);
const bytes = Buffer.from('test archive');
const release = {tag: 'native-42', name: 'archive.zip', digest: createHash('sha256').update(bytes).digest('hex'), url: 'https://example.invalid/archive.zip', authenticated: false};
async function fixture(t) {
  const home = await mkdtemp(join(tmpdir(), 'neura-prepare-'));
  t.after(() => rm(home, {recursive: true, force: true}));
  const data = join(home, 'Library/Application Support/neuraOS/Updates');
  const options = {home, getRelease: async () => release, request: async () => ({ok: true, arrayBuffer: async () => bytes}), commandTimeout: 30};
  return {home, data, options};
}

for (const step of ['/usr/bin/ditto', '/usr/bin/codesign']) {
  test(`timeout in ${step} releases preparation state and permits retry`, async t => {
    const {data, options} = await fixture(t);
    let childStopped = false;
    options.execute = async (command, args, limits) => {
      assert.equal(limits.timeout, 30);
      assert.equal(limits.killSignal, 'SIGKILL');
      if (command !== step) return {stdout: ''};
      const stage = (await readdir(data)).find(name => name.startsWith('stage-'));
      assert(stage);
      await writeFile(join(data, stage, 'partial'), 'incomplete extraction');
      try {
        // Exercise a real subprocess timeout, including a process that ignores TERM.
        return await exec('/bin/sh', ['-c', "trap '' TERM; while :; do :; done"], limits);
      } catch (error) {
        assert.equal(error.signal, 'SIGKILL');
        childStopped = true;
        throw error;
      }
    };
    await assert.rejects(prepare(release.tag, 123, options));
    assert(childStopped);
    assert.deepEqual(await readdir(data), []);
    let retried = false;
    await assert.rejects(prepare(release.tag, 123, {...options, request: async () => {
      retried = true;
      throw new Error('retry reached download');
    }}), /retry reached download/);
    assert(retried);
    assert.deepEqual(await readdir(data), []);
  });
}

test('download timeout removes partial preparation state', async t => {
  const {data, options} = await fixture(t);
  await assert.rejects(prepare(release.tag, 123, {...options, request: async () => {
    throw new DOMException('download timed out', 'TimeoutError');
  }}), /download timed out/);
  assert.deepEqual(await readdir(data), []);
});

test('contending preparation preserves the active installer lock and stage', async t => {
  const {data, options} = await fixture(t);
  await mkdir(join(data, 'install.lock'), {recursive: true});
  await mkdir(join(data, 'stage-active'));
  await writeFile(join(data, 'stage-active/partial'), 'active update');
  await assert.rejects(prepare(release.tag, 123, options), /既に実行中/);
  assert.equal(await readFile(join(data, 'stage-active/partial'), 'utf8'), 'active update');
  assert.deepEqual((await readdir(data)).sort(), ['install.lock', 'stage-active']);
});
