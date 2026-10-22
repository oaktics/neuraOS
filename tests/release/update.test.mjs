import {test} from 'node:test';
import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {validateRelease, verifyArchive} from '../../scripts/native/release/update.mjs';
const bytes = Buffer.from('archive');
const digest = createHash('sha256').update(bytes).digest('hex');
const release = {tag_name: 'native-42', assets: [{name: 'neuraOS-darwin-arm64.zip', digest: `sha256:${digest}`, browser_download_url: 'https://github.com/oaktics/neuraOS/releases/download/native-42/neuraOS-darwin-arm64.zip'}]};
test('accept only matching architecture with authenticated GitHub asset digest', () => {
  assert.equal(validateRelease(release, 'arm64').build, 42);
  assert.throws(() => validateRelease(release, 'x64'));
  assert.throws(() => validateRelease({...release, prerelease: true}, 'arm64'));
  assert.throws(() => validateRelease({...release, draft: true}, 'arm64'));
  assert.throws(() => validateRelease({...release, tag_name: '../../evil'}, 'arm64'));
  assert.throws(() => validateRelease({...release, assets: [{...release.assets[0], digest: null}]}, 'arm64'));
  assert.throws(() => validateRelease({...release, assets: [{...release.assets[0], browser_download_url: 'https://evil.example/archive.zip'}]}, 'arm64'));
});
test('tampered or partial archive is rejected before extraction', () => {
  verifyArchive(bytes, digest);
  assert.throws(() => verifyArchive(Buffer.from('tampered'), digest));
});
