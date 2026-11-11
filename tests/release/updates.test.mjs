import test from 'node:test';
import assert from 'node:assert/strict';
import {generateKeyPairSync} from 'node:crypto';
import {execFileSync} from 'node:child_process';
import {mkdtempSync, writeFileSync, readFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join, resolve} from 'node:path';
import {privateKey, publicKeyBase64, signArchive, verifyArchive, appcastItem, parseItems, updateAppcast} from '../../scripts/native/release/appcast.mjs';
import {sparkleInfoKeys} from '../../scripts/native/release/sparkle.mjs';
import worker from '../../infra/update-worker/src/index.mjs';

const root = resolve(import.meta.dirname, '../..');
function sparkleKey() {
  const {privateKey: key} = generateKeyPairSync('ed25519');
  // Same shape as `generate_keys -x`: the base64 32-byte seed.
  const seed = key.export({format: 'der', type: 'pkcs8'}).subarray(-32).toString('base64');
  return {seed, public: publicKeyBase64(privateKey(seed))};
}
const item = (build, signature = 'sig') => appcastItem({build, version: '0.2.0', url: `https://u.example/releases/neuraOS-${build}-darwin-arm64.zip`, length: 10, signature, date: new Date(0)});

test('archive signatures verify only with the matching key and bytes', () => {
  const key = sparkleKey(), other = sparkleKey(), bytes = Buffer.from('archive');
  const signature = signArchive(bytes, privateKey(key.seed));
  assert.equal(verifyArchive(bytes, signature, key.public), true);
  assert.equal(verifyArchive(Buffer.from('tampered'), signature, key.public), false);
  assert.equal(verifyArchive(bytes, signature, other.public), false);
  // Legacy 64-byte exports (seed + public key) sign identically.
  const legacy = Buffer.concat([Buffer.from(key.seed, 'base64'), Buffer.from(key.public, 'base64')]).toString('base64');
  assert.equal(publicKeyBase64(privateKey(legacy)), key.public);
  assert.throws(() => privateKey('c2hvcnQ='));
});

test('appcast keeps newest releases first and reports pruned archives', () => {
  let xml = '';
  for (const build of [10, 11, 12]) xml = updateAppcast(xml, item(build), build, 2).xml;
  assert.deepEqual(parseItems(xml).map(entry => entry.build), [12, 11]);
  const next = updateAppcast(xml, item(13), 13, 2);
  assert.deepEqual(next.removed, ['https://u.example/releases/neuraOS-11-darwin-arm64.zip']);
  // Re-running the same build replaces its entry instead of duplicating it.
  assert.deepEqual(parseItems(updateAppcast(next.xml, item(13, 'new'), 13, 2).xml).map(entry => entry.build), [13, 12]);
  assert.throws(() => updateAppcast(next.xml, item(9), 9), /newer build/);
  assert.match(next.xml, /xmlns:sparkle="http:\/\/www\.andymatuschak\.org\/xml-namespaces\/sparkle"/);
  assert.match(next.xml, /sparkle:edSignature="sig"/);
});

test('appcast CLI refuses a private key that does not match the app', () => {
  const dir = mkdtempSync(join(tmpdir(), 'neura-appcast-')), key = sparkleKey(), archive = join(dir, 'a.zip');
  writeFileSync(archive, 'archive bytes');
  const args = ['scripts/native/release/appcast.mjs', '--archive', archive, '--build', '42', '--version', '0.2.0',
    '--base-url', 'https://u.example', '--out', join(dir, 'appcast.xml'), '--removed', join(dir, 'removed.txt')];
  assert.throws(() => execFileSync('node', args, {cwd: root, stdio: 'pipe', env: {...process.env, SPARKLE_ED_PRIVATE_KEY: key.seed, NEURA_SPARKLE_PUBLIC_KEY: sparkleKey().public}}));
  execFileSync('node', args, {cwd: root, stdio: 'pipe', env: {...process.env, SPARKLE_ED_PRIVATE_KEY: key.seed, NEURA_SPARKLE_PUBLIC_KEY: key.public}});
  assert.equal(readFileSync(join(dir, 'removed.txt'), 'utf8'), '');
  const [entry] = parseItems(readFileSync(join(dir, 'appcast.xml'), 'utf8'));
  assert.equal(entry.url, 'https://u.example/releases/neuraOS-42-darwin-arm64.zip');
  const signature = /sparkle:edSignature="([^"]+)"/.exec(entry.xml)[1];
  assert.equal(verifyArchive(readFileSync(archive), signature, key.public), true);
});

test('Sparkle keys are release-only and validated', () => {
  assert.equal(sparkleInfoKeys({}), '');
  assert.throws(() => sparkleInfoKeys({NEURA_REQUIRE_UPDATE_FEED: '1'}));
  const key = sparkleKey().public;
  assert.throws(() => sparkleInfoKeys({NEURA_UPDATE_FEED_URL: 'http://u.example/appcast.xml', NEURA_SPARKLE_PUBLIC_KEY: key}));
  assert.throws(() => sparkleInfoKeys({NEURA_UPDATE_FEED_URL: 'https://u.example/appcast.xml', NEURA_SPARKLE_PUBLIC_KEY: 'bad'}));
  const keys = sparkleInfoKeys({NEURA_UPDATE_FEED_URL: 'https://u.example/appcast.xml', NEURA_SPARKLE_PUBLIC_KEY: key});
  assert.match(keys, /<key>SUFeedURL<\/key><string>https:\/\/u\.example\/appcast\.xml<\/string>/);
  assert.match(keys, /<key>SUAutomaticallyUpdate<\/key><false\/>/);
});

// Minimal R2 bucket double implementing the parts of get() the Worker uses.
function bucket(files) {
  return {async get(key, {range} = {}) {
    if (!(key in files)) return null;
    const bytes = Buffer.from(files[key]), header = range?.get('range');
    let slice = bytes, selected;
    const match = header && /^bytes=(\d*)-(\d*)$/.exec(header);
    if (match) {
      // Like production R2, the unused member is present but undefined.
      selected = match[1] === '' ? {offset: undefined, length: undefined, suffix: Number(match[2])} : {offset: Number(match[1]), length: (match[2] === '' ? bytes.length - 1 : Number(match[2])) - Number(match[1]) + 1, suffix: undefined};
      slice = selected.suffix !== undefined ? bytes.subarray(bytes.length - selected.suffix) : bytes.subarray(selected.offset, selected.offset + selected.length);
    }
    return {size: bytes.length, range: selected, httpEtag: '"e"', body: new Blob([slice]).stream(),
      writeHttpMetadata: headers => headers.set('content-type', key.endsWith('.xml') ? 'application/xml' : 'application/zip')};
  }};
}
const env = {UPDATES: bucket({'appcast.xml': '<rss/>', 'releases/neuraOS-42-darwin-arm64.zip': '0123456789'})};
const get = (path, init) => worker.fetch(new Request(`https://u.example${path}`, init), env);

test('Worker serves the appcast without caching and archives with ranges', async () => {
  const feed = await get('/appcast.xml');
  assert.equal(feed.status, 200); assert.equal(await feed.text(), '<rss/>'); assert.equal(feed.headers.get('cache-control'), 'no-cache');
  const archive = await get('/releases/neuraOS-42-darwin-arm64.zip');
  assert.equal(await archive.text(), '0123456789'); assert.match(archive.headers.get('cache-control'), /immutable/);
  const partial = await get('/releases/neuraOS-42-darwin-arm64.zip', {headers: {range: 'bytes=2-4'}});
  assert.equal(partial.status, 206); assert.equal(await partial.text(), '234'); assert.equal(partial.headers.get('content-range'), 'bytes 2-4/10');
  const suffix = await get('/releases/neuraOS-42-darwin-arm64.zip', {headers: {range: 'bytes=-3'}});
  assert.equal(await suffix.text(), '789'); assert.equal(suffix.headers.get('content-range'), 'bytes 7-9/10');
  const head = await get('/releases/neuraOS-42-darwin-arm64.zip', {method: 'HEAD'});
  assert.equal(head.status, 200); assert.equal(head.headers.get('content-length'), '10');
});

test('Worker exposes nothing but the feed and release archives', async () => {
  for (const path of ['/releases/%2e%2e%2fappcast.xml', '/releases/neuraOS-42-darwin-arm64.zip/x', '/releases/other.zip', '/secret', '/releases/neuraOS-1-darwin-arm64.zip'])
    assert.equal((await get(path)).status, 404, path);
  assert.equal((await get('/appcast.xml', {method: 'PUT', body: 'x'})).status, 405);
});

test('pruned archive list is newline-terminated so the shell loop deletes every key', () => {
  const dir = mkdtempSync(join(tmpdir(), 'neura-prune-')), key = sparkleKey(), archive = join(dir, 'a.zip');
  writeFileSync(archive, 'archive bytes');
  let existing = '';
  for (const build of [10, 11, 12]) existing = updateAppcast(existing, appcastItem({build, version: '0.2.0',
    url: `https://u.example/releases/neuraOS-${build}-darwin-arm64.zip`, length: 1, signature: 's'}), build, 10).xml;
  writeFileSync(join(dir, 'current.xml'), existing);
  execFileSync('node', ['scripts/native/release/appcast.mjs', '--archive', archive, '--build', '13', '--version', '0.2.0',
    '--base-url', 'https://u.example', '--existing', join(dir, 'current.xml'), '--keep', '2',
    '--out', join(dir, 'appcast.xml'), '--removed', join(dir, 'removed.txt')],
    {cwd: root, stdio: 'pipe', env: {...process.env, SPARKLE_ED_PRIVATE_KEY: key.seed, NEURA_SPARKLE_PUBLIC_KEY: key.public}});
  assert.equal(readFileSync(join(dir, 'removed.txt'), 'utf8'), 'releases/neuraOS-11-darwin-arm64.zip\nreleases/neuraOS-10-darwin-arm64.zip\n');
  // Same loop as .github/workflows/release.yml.
  const seen = execFileSync('bash', ['-c', 'while IFS= read -r key || [ -n "$key" ]; do [ -n "$key" ] && echo "del $key"; done < "$1"', 'bash', join(dir, 'removed.txt')], {encoding: 'utf8'});
  assert.equal(seen, 'del releases/neuraOS-11-darwin-arm64.zip\ndel releases/neuraOS-10-darwin-arm64.zip\n');
  // The loop also survives a file written without the final newline.
  writeFileSync(join(dir, 'legacy.txt'), 'releases/neuraOS-9-darwin-arm64.zip');
  assert.equal(execFileSync('bash', ['-c', 'while IFS= read -r key || [ -n "$key" ]; do echo "del $key"; done < "$1"', 'bash', join(dir, 'legacy.txt')], {encoding: 'utf8'}),
    'del releases/neuraOS-9-darwin-arm64.zip\n');
});
