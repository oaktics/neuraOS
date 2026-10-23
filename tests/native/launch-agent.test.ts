import {test} from 'node:test';
import assert from 'node:assert/strict';
import {replaceLaunchAgent} from '../../scripts/native/launch-agent.ts';
const failure = (code: number) => Object.assign(new Error(`launchctl ${code}`), {code});
test('bootstrap retries EIO after bootout without removing the job again', async () => {
  const calls: string[] = []; let tries = 0;
  await replaceLaunchAgent('gui/501', 'test', '/tmp/test.plist', {
    execute: async args => {calls.push(args[0]); if (args[0] === 'bootstrap' && ++tries < 3) throw failure(5); return {stdout: '', stderr: ''};},
    pause: async () => {},
  });
  assert.deepEqual(calls, ['bootout', 'bootstrap', 'bootstrap', 'bootstrap']);
});
test('missing job is allowed but bootout permission errors abort', async () => {
  for (const code of [3, 1]) {
    const calls: string[] = [];
    const result = replaceLaunchAgent('gui/501', 'test', '/tmp/test.plist', {
      execute: async args => {calls.push(args[0]); if (args[0] === 'bootout') throw failure(code); return {stdout: '', stderr: ''};}, pause: async () => {},
    });
    if (code === 3) {await result; assert.equal(calls.length, 2);}
    else {await assert.rejects(result, /launchctl 1/); assert.equal(calls.length, 1);}
  }
});
test('permanent bootstrap failure is bounded and non-EIO errors are not retried', async () => {
  for (const code of [5, 1]) {
    let tries = 0;
    await assert.rejects(replaceLaunchAgent('gui/501', 'test', '/tmp/test.plist', {
      execute: async args => {if (args[0] === 'bootstrap') {tries++; throw failure(code);} return {stdout: '', stderr: ''};}, pause: async () => {},
    }), new RegExp(`launchctl ${code}`));
    assert.equal(tries, code === 5 ? 20 : 1);
  }
});
