import {execFileSync, spawnSync} from 'node:child_process';
import {mkdtempSync, rmSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join, resolve} from 'node:path';

const app = resolve(process.env.NEURA_APP_OUTPUT ?? 'apps/macos/dist/neuraOS.app');
const profile = process.env.NEURA_NOTARY_PROFILE;
if (!profile) throw new Error('NEURA_NOTARY_PROFILE is required');
const auth = ['--keychain-profile', profile,
  ...(process.env.NEURA_SIGN_KEYCHAIN ? ['--keychain', process.env.NEURA_SIGN_KEYCHAIN] : [])];
const run = (command, args) => execFileSync(command, args, {stdio: 'inherit'});
run('codesign', ['--verify', '--deep', '--strict', app]);
// Reject an ad-hoc or development-signed app before uploading it.
const details = spawnSync('codesign', ['-d', '--verbose=4', app], {encoding: 'utf8'});
if (details.status !== 0 || !details.stderr.includes('Authority=Developer ID Application:') || !details.stderr.includes('Timestamp='))
  throw new Error('Notarization requires timestamped Developer ID Application signing');
const temporary = mkdtempSync(join(tmpdir(), 'neura-notary-'));
try {
  const archive = join(temporary, 'neuraOS.zip');
  console.log('Creating notarization archive…');
  run('ditto', ['-c', '-k', '--sequesterRsrc', '--keepParent', app, archive]);
  console.log('Uploading to Apple…');
  const submitted = JSON.parse(execFileSync('xcrun', ['notarytool', 'submit', archive, ...auth,
    '--output-format', 'json'], {encoding: 'utf8', stdio: ['ignore', 'pipe', 'inherit']}));
  if (!submitted.id) throw new Error('Apple did not return a submission ID');
  // Record the ID before waiting: a timeout does not cancel Apple's work.
  writeFileSync(`${app}.notarization.json`, JSON.stringify(submitted, null, 2) + '\n');
  console.log(`Submitted ${submitted.id}; waiting for Apple (up to 30 minutes).`);
  const result = JSON.parse(execFileSync('xcrun', ['notarytool', 'wait', submitted.id, ...auth,
    '--timeout', '30m', '--output-format', 'json'], {encoding: 'utf8', stdio: ['ignore', 'pipe', 'inherit']}));
  writeFileSync(`${app}.notarization.json`, JSON.stringify(result, null, 2) + '\n');
  console.log(`Notarization ${result.id}: ${result.status}`);
  if (result.status !== 'Accepted') {
    if (result.id) run('xcrun', ['notarytool', 'log', result.id, ...auth]);
    throw new Error('Notarization was not accepted');
  }
  run('xcrun', ['stapler', 'staple', app]);
  run('xcrun', ['stapler', 'validate', app]);
  run('codesign', ['--verify', '--deep', '--strict', app]);
  run('spctl', ['--assess', '--type', 'execute', '--verbose=2', app]);
} finally {rmSync(temporary, {recursive: true, force: true});}
