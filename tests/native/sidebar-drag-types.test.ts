import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {readFileSync} from 'node:fs';
import test from 'node:test';
import {appInfoPlist} from '../../scripts/native/app-info.mjs';

// Parse the same complete plist that build.mjs writes, rather than testing a
// parallel list of constants that could omit the bundle packaging step.
test('bundle declares every exported Swift drag type and its pasteboard mapping', {skip: process.platform !== 'darwin'}, () => {
 const source = readFileSync(new URL('../../apps/macos/Sources/NeuraOS/SidebarSpaces.swift', import.meta.url), 'utf8');
 const identifiers = [...source.matchAll(/UTType\(exportedAs: "([^"]+)"/g)].map(match => match[1]);
 assert.equal(identifiers.length, 2);
 const xml = appInfoPlist({bundleId: 'com.neuraos.reorder-test', version: '1.0', build: '1', dataDirectory: '/tmp/test & data', port: '49395'});
 const plist = JSON.parse(execFileSync('/usr/bin/plutil', ['-convert', 'json', '-o', '-', '-'], {input: xml, encoding: 'utf8'}));
 for (const id of identifiers) {
  const entries = plist.UTExportedTypeDeclarations.filter((entry: {UTTypeIdentifier: string}) => entry.UTTypeIdentifier === id);
  assert.equal(entries.length, 1, `${id} must be declared once in the application bundle`);
  assert.ok(entries[0].UTTypeConformsTo.includes('public.data'));
  assert.ok(entries[0].UTTypeTagSpecification['com.apple.nspboard-type'].includes(id));
 }
 assert.equal(plist.NeuraDataDirectory, '/tmp/test & data');
 assert.equal(plist.NeuraEndpoint, 'http://127.0.0.1:49395');
 const build = readFileSync(new URL('../../scripts/native/build.mjs', import.meta.url), 'utf8');
 assert.match(build, /writeFile\(join\(output,'Contents\/Info.plist'\), appInfoPlist\(/);
});

test('built application includes the sidebar drag declarations', {skip: process.platform !== 'darwin' || !process.env.NEURA_TEST_APP_BUNDLE}, () => {
 const plist = JSON.parse(execFileSync('/usr/bin/plutil', ['-convert', 'json', '-o', '-', `${process.env.NEURA_TEST_APP_BUNDLE}/Contents/Info.plist`], {encoding: 'utf8'}));
 for (const id of ['com.neuraos.sidebar-project', 'com.neuraos.sidebar-space']) {
  const declaration = plist.UTExportedTypeDeclarations?.find((entry: {UTTypeIdentifier: string}) => entry.UTTypeIdentifier === id);
  assert.ok(declaration, `Built bundle is missing ${id}`);
  assert.ok(declaration.UTTypeConformsTo.includes('public.data'));
  assert.ok(declaration.UTTypeTagSpecification['com.apple.nspboard-type'].includes(id));
 }
});
