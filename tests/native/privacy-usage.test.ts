import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import test from 'node:test';
import {fileURLToPath} from 'node:url';
import {appInfoPlist} from '../../scripts/native/app-info.mjs';

// macOS aborts the whole app (TCC privacy violation) when a website reaches a
// protected resource and the bundle has no usage string for it. Every resource
// entitlement the signed app carries therefore needs its Info.plist key.
const usageKeys: Record<string, string> = {
 'com.apple.security.device.audio-input': 'NSMicrophoneUsageDescription',
 'com.apple.security.device.camera': 'NSCameraUsageDescription',
 'com.apple.security.device.bluetooth': 'NSBluetoothAlwaysUsageDescription',
 'com.apple.security.personal-information.location': 'NSLocationUsageDescription',
};
const resource = (key: string) => key.startsWith('com.apple.security.device.') || key.startsWith('com.apple.security.personal-information.');
const json = (args: string[], input?: string) => JSON.parse(execFileSync('/usr/bin/plutil', ['-convert', 'json', '-o', '-', ...args], {input, encoding: 'utf8'}));
const entitlements = (name: string) => json([fileURLToPath(new URL(`../../scripts/native/signing/${name}.entitlements.plist`, import.meta.url))]);

test('bundle declares a usage description for every resource a website can reach', {skip: process.platform !== 'darwin'}, () => {
 const plist = json(['-'], appInfoPlist({bundleId: 'com.neuraos.privacy-test', version: '1.0', build: '1'}));
 const resources = Object.keys(entitlements('certified-client')).filter(resource);
 for (const required of Object.keys(usageKeys)) assert.ok(resources.includes(required), `Signed app is missing ${required}`);
 for (const key of [...resources.map(entry => {
  assert.ok(usageKeys[entry], `${entry} has no known usage description key`);
  return usageKeys[entry];
 }), 'NSAudioCaptureUsageDescription', 'NSLocalNetworkUsageDescription', 'NSLocationWhenInUseUsageDescription']) {
  assert.equal(typeof plist[key], 'string', `Info.plist is missing ${key}`);
  assert.ok(plist[key].trim().length > 0, `${key} must not be empty`);
 }
});

test('local builds grant websites the same resources as signed releases', {skip: process.platform !== 'darwin'}, () => {
 const local = Object.keys(entitlements('client')).filter(resource).sort();
 assert.deepEqual(local, Object.keys(entitlements('certified-client')).filter(resource).sort());
});

// Existing Launch Services registrations may survive an update; new bundles
// must not advertise themselves as HTTP(S) handlers.
test('development browser does not register web URL schemes', {skip: process.platform !== 'darwin'}, () => {
 const plist = json(['-'], appInfoPlist({bundleId: 'app.neuraos.native', version: '1.0', build: '1'}));
 assert.equal(plist.CFBundleURLTypes, undefined);
});
