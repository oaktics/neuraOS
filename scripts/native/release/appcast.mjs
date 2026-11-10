// Signs a release archive for Sparkle and writes the appcast served by the
// update Worker (infra/update-worker). Signing uses Node's Ed25519, which is
// the same scheme as Sparkle's sign_update, so CI needs no Sparkle tools.
import {createPrivateKey, createPublicKey, sign, verify} from 'node:crypto';
import {readFileSync, writeFileSync, statSync, existsSync} from 'node:fs';
import {parseArgs} from 'node:util';
import {pathToFileURL} from 'node:url';

const PKCS8_ED25519 = Buffer.from('302e020100300506032b657004220420', 'hex');
const SPKI_ED25519 = Buffer.from('302a300506032b6570032100', 'hex');
const SPARKLE_NS = 'http://www.andymatuschak.org/xml-namespaces/sparkle';

// `generate_keys -x` exports the 32-byte seed (older versions: seed + public key).
export function privateKey(base64) {
  const bytes = Buffer.from((base64 ?? '').trim(), 'base64');
  if (bytes.length !== 32 && bytes.length !== 64) throw new Error('SPARKLE_ED_PRIVATE_KEY must be a base64 Ed25519 key exported by generate_keys -x');
  return createPrivateKey({key: Buffer.concat([PKCS8_ED25519, bytes.subarray(0, 32)]), format: 'der', type: 'pkcs8'});
}
export function publicKeyBase64(key) {
  return createPublicKey(key).export({format: 'der', type: 'spki'}).subarray(-32).toString('base64');
}
export function signArchive(bytes, key) {return sign(null, bytes, key).toString('base64');}
export function verifyArchive(bytes, signature, publicBase64) {
  const key = createPublicKey({key: Buffer.concat([SPKI_ED25519, Buffer.from(publicBase64, 'base64')]), format: 'der', type: 'spki'});
  return verify(null, bytes, key, Buffer.from(signature, 'base64'));
}

const escape = value => String(value).replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('"', '&quot;');

export function appcastItem({build, version, url, length, signature, date = new Date(), notes = '', minimumSystemVersion = '14.0'}) {
  if (!Number.isSafeInteger(build) || build <= 0) throw new Error('Invalid build number');
  return [
    '    <item>',
    `      <title>neuraOS ${escape(version)} (${build})</title>`,
    `      <pubDate>${date.toUTCString()}</pubDate>`,
    `      <sparkle:version>${build}</sparkle:version>`,
    `      <sparkle:shortVersionString>${escape(version)}</sparkle:shortVersionString>`,
    `      <sparkle:minimumSystemVersion>${escape(minimumSystemVersion)}</sparkle:minimumSystemVersion>`,
    `      <description><![CDATA[${notes.replaceAll(']]>', ']]&gt;')}]]></description>`,
    `      <enclosure url="${escape(url)}" length="${length}" type="application/octet-stream" sparkle:edSignature="${escape(signature)}"/>`,
    '    </item>',
  ].join('\n');
}

export function parseItems(xml) {
  return [...(xml ?? '').matchAll(/ *<item>[\s\S]*?<\/item>/g)].map(match => ({
    xml: match[0].replace(/^ */, '    '),
    build: Number(/<sparkle:version>(\d+)<\/sparkle:version>/.exec(match[0])?.[1] ?? 0),
    url: /<enclosure[^>]*\burl="([^"]+)"/.exec(match[0])?.[1]?.replaceAll('&amp;', '&'),
  })).filter(item => item.build > 0 && item.url);
}

// Newest first. Keeps `keep` releases so a skipped-over Mac can still find
// the latest one, and reports the archives that fell out of the feed.
export function updateAppcast(existing, item, build, keep = 10) {
  const current = parseItems(existing).filter(entry => entry.build !== build);
  if (current.some(entry => entry.build > build)) throw new Error(`The appcast already contains a newer build than ${build}`);
  const items = [{xml: item, build}, ...current].sort((a, b) => b.build - a.build);
  const kept = items.slice(0, keep), removed = items.slice(keep).map(entry => entry.url);
  const xml = [
    '<?xml version="1.0" encoding="utf-8"?>',
    `<rss version="2.0" xmlns:sparkle="${SPARKLE_NS}">`,
    '  <channel>',
    '    <title>neuraOS</title>',
    ...kept.map(entry => entry.xml),
    '  </channel>',
    '</rss>',
    '',
  ].join('\n');
  return {xml, removed};
}

export function releaseNotes(commit) {
  return '<p>更新するとDaemonも再起動し、実行中のターミナル・エージェントは停止します。作業を保存してから「インストールして再起動」を選んでください。</p>' +
    (commit ? `<p style="color:gray">main ${escape(commit.slice(0, 12))} からビルド</p>` : '');
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const {values} = parseArgs({options: {
    archive: {type: 'string'}, build: {type: 'string'}, version: {type: 'string'}, 'base-url': {type: 'string'},
    existing: {type: 'string'}, out: {type: 'string'}, removed: {type: 'string'}, commit: {type: 'string'}, keep: {type: 'string', default: '10'},
  }});
  for (const name of ['archive', 'build', 'version', 'base-url', 'out', 'removed'])
    if (!values[name]) throw new Error(`--${name} is required`);
  const build = Number(values.build), base = values['base-url'].replace(/\/+$/, '');
  if (!/^https:\/\//.test(base)) throw new Error('--base-url must be https');
  const key = privateKey(process.env.SPARKLE_ED_PRIVATE_KEY);
  const expected = process.env.NEURA_SPARKLE_PUBLIC_KEY;
  // A key that does not match the public key inside the app would make every
  // installed copy reject this and all later updates. Fail before publishing.
  if (!expected || publicKeyBase64(key) !== expected) throw new Error('SPARKLE_ED_PRIVATE_KEY does not match NEURA_SPARKLE_PUBLIC_KEY');
  const bytes = readFileSync(values.archive);
  const signature = signArchive(bytes, key);
  if (!verifyArchive(bytes, signature, expected)) throw new Error('Signature self-check failed');
  const name = `neuraOS-${build}-darwin-arm64.zip`;
  const item = appcastItem({build, version: values.version, url: `${base}/releases/${name}`, length: statSync(values.archive).size,
    signature, notes: releaseNotes(values.commit)});
  const existing = values.existing && existsSync(values.existing) ? readFileSync(values.existing, 'utf8') : '';
  // A rerun of an older workflow must not roll the feed back.
  const newest = Math.max(0, ...parseItems(existing).map(entry => entry.build));
  if (newest > build) {console.log(`Build ${newest} is already published; leaving the feed unchanged.`); process.exit(0);}
  const {xml, removed} = updateAppcast(existing, item, build, Number(values.keep));
  writeFileSync(values.out, xml);
  // Only archives under this feed's /releases/ are ever pruned.
  writeFileSync(values.removed, removed.filter(url => url.startsWith(`${base}/releases/`))
    .map(url => url.slice(base.length + 1)).filter(key => /^releases\/neuraOS-\d+-darwin-arm64\.zip$/.test(key)).join('\n'));
  console.log(`Signed ${name} (${bytes.length} bytes); appcast keeps ${parseItems(xml).length} releases`);
}
