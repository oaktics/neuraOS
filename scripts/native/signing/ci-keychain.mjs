import {execFileSync} from 'node:child_process';
import {randomBytes} from 'node:crypto';
import {writeFileSync, readFileSync, existsSync, rmSync} from 'node:fs';
import {join} from 'node:path';

if (process.env.GITHUB_ACTIONS !== 'true' || !process.env.RUNNER_TEMP) throw new Error('CI keychain setup is restricted to GitHub Actions');
const keychain = join(process.env.RUNNER_TEMP, 'neura-signing.keychain-db');
const saved = join(process.env.RUNNER_TEMP, 'neura-keychain-search-list.json');
const certificate = join(process.env.RUNNER_TEMP, 'neura-signing.p12');
// Never let child-process error objects (which include argv) expose credentials.
function run(command, args) {
  try {return execFileSync(command, args, {encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe']});}
  catch {throw new Error(`${command} failed during CI keychain configuration; credential output suppressed`);}
}
if (process.argv[2] === 'cleanup') {
  try {
    if (existsSync(saved)) run('security', ['list-keychains', '-d', 'user', '-s', ...JSON.parse(readFileSync(saved, 'utf8'))]);
  } finally {
    try {if (existsSync(keychain)) run('security', ['delete-keychain', keychain]);}
    finally {rmSync(certificate, {force: true}); rmSync(saved, {force: true});}
  }
} else if (process.argv[2] === 'setup') {
  for (const name of ['APPLE_CERTIFICATE_P12_BASE64', 'APPLE_CERTIFICATE_PASSWORD', 'APPLE_ID', 'APPLE_TEAM_ID', 'APPLE_APP_SPECIFIC_PASSWORD']) {
    if (!process.env[name]) throw new Error(`Missing required release secret: ${name}`);
  }
  const previous = [...run('security', ['list-keychains', '-d', 'user']).matchAll(/"([^"]+)"/g)].map(match => match[1]);
  writeFileSync(saved, JSON.stringify(previous), {mode: 0o600});
  const password = randomBytes(32).toString('hex');
  run('security', ['create-keychain', '-p', password, keychain]);
  run('security', ['set-keychain-settings', '-lut', '21600', keychain]);
  run('security', ['unlock-keychain', '-p', password, keychain]);
  writeFileSync(certificate, Buffer.from(process.env.APPLE_CERTIFICATE_P12_BASE64, 'base64'), {mode: 0o600});
  try {
    run('security', ['import', certificate, '-k', keychain, '-P', process.env.APPLE_CERTIFICATE_PASSWORD, '-T', '/usr/bin/codesign']);
  } finally {rmSync(certificate, {force: true});}
  run('security', ['set-key-partition-list', '-S', 'apple-tool:,apple:,codesign:', '-s', '-k', password, keychain]);
  run('security', ['list-keychains', '-d', 'user', '-s', keychain, ...previous]);
  run('xcrun', ['notarytool', 'store-credentials', 'neura-release', '--keychain', keychain,
    '--apple-id', process.env.APPLE_ID, '--team-id', process.env.APPLE_TEAM_ID, '--password', process.env.APPLE_APP_SPECIFIC_PASSWORD]);
} else {throw new Error('Expected setup or cleanup');}
