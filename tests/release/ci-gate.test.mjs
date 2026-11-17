import {readFileSync} from 'node:fs';
import {spawnSync} from 'node:child_process';
import assert from 'node:assert/strict';
import test from 'node:test';

const workflow = readFileSync(new URL('../../.github/workflows/check.yml', import.meta.url), 'utf8');
const gate = workflow.split('  macos:\n')[1].split('        run: |\n')[1]
  .split('\n').map(line => line.replace(/^          /, '')).join('\n');
const results = ['RUST_RESULT', 'NODE_RESULT', 'SWIFT_RESULT', 'PACKAGE_RESULT'];
function passes(overrides = {}) {
  return spawnSync('bash', ['-e', '-c', gate], {env: {
    ...process.env, CHANGES_RESULT: 'success', REQUIRED: 'true', EVENT_NAME: 'pull_request',
    ...Object.fromEntries(results.map(key => [key, 'success'])), ...overrides,
  }}).status === 0;
}
test('aggregate accepts full PR, schedule and dispatch validation', () => {
  for (const EVENT_NAME of ['pull_request', 'schedule', 'workflow_dispatch']) assert.ok(passes({EVENT_NAME}));
});
test('aggregate rejects every unsuccessful required job and change detection', () => {
  for (const key of [...results, 'CHANGES_RESULT']) {
    for (const result of ['failure', 'cancelled', 'skipped', '']) assert.equal(passes({[key]: result}), false, `${key}=${result}`);
  }
  assert.equal(passes({REQUIRED: ''}), false);
});
test('push requires Rust and Node but intentionally skips packaging and Swift', () => {
  const push = {EVENT_NAME: 'push', SWIFT_RESULT: 'skipped', PACKAGE_RESULT: 'skipped'};
  assert.ok(passes(push));
  for (const key of ['RUST_RESULT', 'NODE_RESULT']) assert.equal(passes({...push, [key]: 'cancelled'}), false);
  assert.equal(passes({...push, PACKAGE_RESULT: 'failure'}), false);
});
test('documentation-only changes pass only with all validation jobs skipped', () => {
  const docs = {REQUIRED: 'false', ...Object.fromEntries(results.map(key => [key, 'skipped']))};
  assert.ok(passes(docs));
  for (const key of results) assert.equal(passes({...docs, [key]: 'cancelled'}), false);
  assert.equal(passes({...docs, CHANGES_RESULT: 'failure'}), false);
});
