import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtempSync, mkdirSync, writeFileSync, symlinkSync, rmSync} from 'node:fs';
import {join} from 'node:path';
import {tmpdir} from 'node:os';
import {selectIdentity, signCertifiedTree, isMachO} from '../../scripts/native/signing/sign.mjs';

test('local signing never silently falls back to ad-hoc or picks an ambiguous team', () => {
  const identity = 'Developer ID Application: Example (TEAM)';
  assert.equal(selectIdentity({}, `1) HASH "${identity}"`), identity);
  assert.throws(() => selectIdentity({}, '0 valid identities'), /NEURA_SIGN_IDENTITY/);
  assert.throws(() => selectIdentity({}, `"${identity}" "Developer ID Application: Other (OTHER)"`), /NEURA_SIGN_IDENTITY/);
  assert.equal(selectIdentity({NEURA_SIGN_IDENTITY: '-'}), '-');
  for (const identity of ['-', 'Apple Development: Example (TEAM)'])
    assert.throws(() => selectIdentity({NEURA_SIGN_IDENTITY: identity, NEURA_REQUIRE_DEVELOPER_ID: '1'}), /Release requires/);
});

test('nested signing discovers arbitrary Mach-O files, skips symlinks, and seals containers last', t => {
  const root = mkdtempSync(join(tmpdir(), 'neura-sign-test-'));
  t.after(() => rmSync(root, {recursive: true, force: true}));
  const app = join(root, 'Example.app');
  const framework = join(app, 'Contents/Frameworks/Example.framework');
  const renderer = join(app, 'Contents/Frameworks/NeuraOS Helper (Renderer).app');
  const paths = [join(framework, 'Versions/A/Libraries/unexpected-name'),
    join(renderer, 'Contents/MacOS/helper'), join(app, 'Contents/Resources/Runtime/bin/node'),
    join(app, 'Contents/MacOS/NeuraSleepService')];
  for (const path of paths) {mkdirSync(join(path, '..'), {recursive: true}); writeFileSync(path, Buffer.from('cffaedfe00000000', 'hex'));}
  const text = join(app, 'Contents/Resources/plain');
  writeFileSync(text, 'not executable');
  symlinkSync('A', join(framework, 'Versions/Current'));
  symlinkSync(app, join(app, 'loop'));
  assert.equal(isMachO(text), false);
  const commands = [];
  signCertifiedTree(app, 'Developer ID Application: Example (TEAM)', (command, args) => commands.push(args));
  const signed = commands.filter(args => args.includes('--sign'));
  const targets = signed.map(args => args.at(-1));
  for (const path of paths) assert.equal(targets.filter(target => target === path).length, 1);
  assert.ok(targets.indexOf(paths[0]) < targets.indexOf(framework));
  assert.ok(targets.indexOf(paths[1]) < targets.indexOf(renderer));
  assert.equal(targets.at(-1), app);
  assert.ok(!targets.includes(text));
  for (const args of signed) {assert.ok(args.includes('--timestamp')); assert.ok(!args.includes('--deep'));}
  const entitlement = target => signed.find(args => args.at(-1) === target)[signed.find(args => args.at(-1) === target).indexOf('--entitlements') + 1];
  assert.ok(entitlement(renderer).endsWith('/jit.entitlements.plist'));
  assert.ok(entitlement(paths[2]).endsWith('/jit.entitlements.plist'));
  assert.ok(entitlement(paths[3]).endsWith('/empty.entitlements.plist'));
  assert.ok(entitlement(app).endsWith('/certified-client.entitlements.plist'));
  assert.deepEqual(commands.at(-1), ['--verify', '--deep', '--strict', app]);
});
