import {cp, rm, mkdir, copyFile} from 'node:fs/promises';
import {join} from 'node:path';

const escape = value => value.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');

// Sparkle's update feed and EdDSA public key are baked into release builds.
// Development and PR builds omit them, which keeps Sparkle disabled there.
export function sparkleInfoKeys(env = process.env) {
  const feed = env.NEURA_UPDATE_FEED_URL ?? '';
  const key = env.NEURA_SPARKLE_PUBLIC_KEY ?? '';
  if (!feed && !key) {
    if (env.NEURA_REQUIRE_UPDATE_FEED === '1')
      throw new Error('Release builds require NEURA_UPDATE_FEED_URL and NEURA_SPARKLE_PUBLIC_KEY');
    return '';
  }
  if (!/^https:\/\/[^\s<>&"]+\/appcast\.xml$/.test(feed)) throw new Error('NEURA_UPDATE_FEED_URL must be an https URL ending in /appcast.xml');
  if (Buffer.from(key, 'base64').length !== 32 || !/^[A-Za-z0-9+/]+=*$/.test(key))
    throw new Error('NEURA_SPARKLE_PUBLIC_KEY must be a base64 Ed25519 public key');
  // Check daily, but never download or install without the user: an update
  // restarts the daemon and stops running terminals.
  return `<key>SUFeedURL</key><string>${escape(feed)}</string>` +
    `<key>SUPublicEDKey</key><string>${key}</string>` +
    '<key>SUEnableAutomaticChecks</key><true/>' +
    '<key>SUScheduledCheckInterval</key><integer>86400</integer>' +
    '<key>SUAllowsAutomaticUpdates</key><false/>' +
    '<key>SUAutomaticallyUpdate</key><false/>' +
    '<key>SUVerifyUpdateBeforeExtraction</key><true/>';
}

// Embed Sparkle.framework from the SwiftPM binary artifact. neuraOS is not
// sandboxed, so the XPC services are unnecessary; headers are build-only.
export async function bundleSparkle(app, native) {
  const source = join(native, '.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework');
  const frameworks = join(app, 'Contents/Frameworks'), framework = join(frameworks, 'Sparkle.framework');
  await mkdir(frameworks, {recursive: true});
  await rm(framework, {recursive: true, force: true});
  await cp(source, framework, {recursive: true, verbatimSymlinks: true});
  for (const name of ['XPCServices', 'Headers', 'PrivateHeaders', 'Modules']) {
    await rm(join(framework, name), {force: true});
    await rm(join(framework, 'Versions/B', name), {recursive: true, force: true});
  }
  const license = join(app, 'Contents/Resources/Licenses/Sparkle.txt');
  await rm(license, {force: true});
  await copyFile(join(native, '.build/checkouts/Sparkle/LICENSE'), license);
}
