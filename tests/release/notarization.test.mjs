import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtempSync, mkdirSync, writeFileSync, symlinkSync, readFileSync, rmSync} from 'node:fs';
import {spawnSync} from 'node:child_process';
import {tmpdir} from 'node:os';
import {join, resolve} from 'node:path';

for (const status of ['Accepted', 'Invalid', 'timeout']) {
  test(`notarization ${status}: retain submission ID and gate stapling`, t => {
    const root = mkdtempSync(join(tmpdir(), 'neura-notary-test-'));
    t.after(() => rmSync(root, {recursive: true, force: true}));
    const bin = join(root, 'bin'), app = join(root, 'Example.app'), log = join(root, 'commands.jsonl');
    mkdirSync(bin); mkdirSync(app);
    const stub = join(bin, 'stub');
    writeFileSync(stub, `#!${process.execPath}
const fs = require('node:fs');
const name = require('node:path').basename(process.argv[1]);
const args = process.argv.slice(2);
fs.appendFileSync(process.env.COMMAND_LOG, JSON.stringify([name, ...args]) + '\\n');
if (name === 'codesign' && args.includes('-d')) console.error('Authority=Developer ID Application: Example (TEAM)\\nTimestamp=today');
if (name === 'xcrun' && args[0] === 'notarytool') {
  if (args[1] === 'submit') console.log(JSON.stringify({id:'submission-123', message:'uploaded'}));
  if (args[1] === 'wait') {
    if (process.env.NOTARY_STATUS === 'timeout') process.exit(1);
    console.log(JSON.stringify({id:'submission-123', status:process.env.NOTARY_STATUS}));
  }
}
`, {mode: 0o755});
    for (const name of ['codesign', 'ditto', 'xcrun', 'spctl']) symlinkSync(stub, join(bin, name));
    const result = spawnSync(process.execPath, [resolve('scripts/native/signing/notarize.mjs')], {
      encoding: 'utf8', env: {...process.env, PATH: bin, TMPDIR: root, NEURA_APP_OUTPUT: app,
        NEURA_NOTARY_PROFILE: 'test-profile', COMMAND_LOG: log, NOTARY_STATUS: status},
    });
    assert.equal(result.status, status === 'Accepted' ? 0 : 1, result.stderr);
    assert.equal(JSON.parse(readFileSync(`${app}.notarization.json`, 'utf8')).id, 'submission-123');
    const commands = readFileSync(log, 'utf8').trim().split('\n').map(line => JSON.parse(line));
    assert.equal(commands.some(c => c[0] === 'xcrun' && c[1] === 'stapler' && c[2] === 'staple'), status === 'Accepted');
    assert.equal(commands.some(c => c[0] === 'spctl'), status === 'Accepted');
    if (status === 'Invalid') assert.ok(commands.some(c => c[0] === 'xcrun' && c[2] === 'log'));
    assert.match(result.stdout, /Submitted submission-123/);
  });
}
