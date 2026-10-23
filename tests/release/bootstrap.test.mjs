import {test} from 'node:test';
import assert from 'node:assert/strict';
import {mkdtemp, readFile, rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {runBootstrapCommand} from '../../scripts/native/release/update.mjs';

test('bootstrap timeout stops TERM-ignoring service and descendant before returning', {timeout: 10000}, async t => {
  const dir = await mkdtemp(join(tmpdir(), 'bootstrap-timeout-'));
  t.after(() => rm(dir, {recursive: true, force: true}));
  const pidFile = join(dir, 'pids');
  await assert.rejects(runBootstrapCommand('/bin/sh', ['-c',
    'trap "" TERM; /bin/sh -c \'trap "" TERM; while :; do :; done\' & echo "$$ $!" > "$1"; wait',
    'test', pidFile], 1000), /bootstrap timed out/);
  const pids = (await readFile(pidFile, 'utf8')).trim().split(' ').map(Number);
  for (const pid of pids) {
    let alive = true;
    for (let i = 0; i < 100; i++) {
      try {process.kill(pid, 0);} catch (error) {assert.equal(error.code, 'ESRCH'); alive = false; break;}
      await new Promise(r => setTimeout(r, 20));
    }
    assert.equal(alive, false, `process ${pid} survived timeout`);
  }
});

test('bootstrap command returns successful output', async () => {
  assert.equal((await runBootstrapCommand('/bin/echo', ['ready'])).stdout.trim(), 'ready');
});
