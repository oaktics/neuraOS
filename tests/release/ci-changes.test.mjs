import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtempSync, rmSync, writeFileSync, mkdirSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {execFileSync} from 'node:child_process';
import {docsOnly, needsChecks, needsReleaseChecks} from '../../scripts/ci/changes.mjs';

test('only known documentation paths bypass checks', () => {
  assert.equal(docsOnly(['README.md', 'docs/design.svg', '.github/pull_request_template.md']), true);
  for (const paths of [[], ['tests/fixtures/input.md'], ['README.md', 'package.json'], ['.github/workflows/check.yml']]) {
    assert.equal(docsOnly(paths), false);
  }
  assert.equal(needsChecks('schedule', {}), true);
  assert.equal(needsChecks('workflow_dispatch', {}), true);
  assert.equal(needsChecks('push', {before: '0'.repeat(40)}), true);
});

test('PR comparison excludes base-only changes and code moved into docs still runs checks', () => {
  const dir = mkdtempSync(join(tmpdir(), 'neura-ci-'));
  const git = args => execFileSync('git', args, {cwd: dir, encoding: 'utf8'});
  try {
    git(['init', '-b', 'staging']);
    git(['config', 'user.email', 'ci@example.test']);
    git(['config', 'user.name', 'CI Test']);
    writeFileSync(join(dir, 'app.js'), 'code');
    git(['add', '.']); git(['commit', '-m', 'initial']);
    const initial = git(['rev-parse', 'HEAD']).trim();
    git(['checkout', '-b', 'docs']);
    writeFileSync(join(dir, 'README.md'), 'docs');
    git(['add', '.']); git(['commit', '-m', 'docs']);
    const head = git(['rev-parse', 'HEAD']).trim();
    git(['checkout', 'staging']);
    writeFileSync(join(dir, 'app.js'), 'changed');
    git(['add', '.']); git(['commit', '-m', 'base changes']);
    const base = git(['rev-parse', 'HEAD']).trim();
    assert.equal(needsChecks('pull_request', {pull_request: {base: {sha: base}, head: {sha: head}}}, git), false);
    assert.equal(needsChecks('push', {before: initial, after: head}, git), false);
    assert.equal(needsChecks('push', {before: head, after: base}, git), true);
    mkdirSync(join(dir, 'docs'));
    git(['mv', 'app.js', 'docs/app.js']);
    git(['commit', '-m', 'move code into docs']);
    assert.equal(needsChecks('push', {before: base, after: git(['rev-parse', 'HEAD']).trim()}, git), true);
  } finally { rmSync(dir, {recursive: true, force: true}); }
});

test('release docs pushes retain code changes since the last published commit', () => {
  const published = '1'.repeat(40), before = '2'.repeat(40), after = '3'.repeat(40);
  const event = {before, after};
  const git = args => {
    assert.deepEqual(args.slice(4, 6), [published, after]);
    return 'app.js\0README.md\0';
  };
  assert.equal(needsReleaseChecks('push', event, published, git), true);
  assert.equal(needsReleaseChecks('push', event, published, () => 'README.md\0'), false);
  assert.equal(needsReleaseChecks('push', event, undefined, () => { throw new Error('No release base'); }), true);
});
