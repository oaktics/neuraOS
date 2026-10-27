import {signApplication} from './signing/sign.mjs';
import {execFileSync} from 'node:child_process';
import {mkdir,cp,writeFile,copyFile,rm,readdir,readFile} from 'node:fs/promises';
import {resolve,join} from 'node:path';
import {prepareChromium} from './chromium/prepare.mjs';
import {bundleChromium} from './chromium/bundle.mjs';
await prepareChromium();
const root=resolve(import.meta.dirname,'../..'),native=join(root,'apps/macos');
const output=process.env.NEURA_APP_OUTPUT??join(native,'dist/neuraOS.app');
const version=JSON.parse(await readFile(join(root,'package.json'),'utf8')).version;
const build=process.env.NEURA_BUILD_NUMBER??'0';
if(!/^\d+$/.test(build))throw new Error('Invalid build number');
const escape=value=>value.replaceAll('&','&amp;').replaceAll('<','&lt;').replaceAll('>','&gt;');
execFileSync('swift',['build','--package-path',native,'-c','release','--force-resolved-versions',...(process.env.NEURA_SWIFT_BUILD_SYSTEM?['--build-system',process.env.NEURA_SWIFT_BUILD_SYSTEM]:[])],{stdio:'inherit'});
await mkdir(join(output,'Contents/MacOS'),{recursive:true});
await mkdir(join(output,'Contents/Resources'),{recursive:true});
await copyFile(join(native,'Assets/AppIcon.icns'),join(output,'Contents/Resources/AppIcon.icns'));
await rm(join(output,'Contents/Resources/Terminal'),{recursive:true,force:true});
await copyFile(join(native,'.build/release/NeuraOS'),join(output,'Contents/MacOS/NeuraOS'));
await rm(join(output,'Contents/MacOS/NeuraSleepHelper'),{force:true});
await copyFile(join(native,'.build/release/NeuraSleepService'),join(output,'Contents/MacOS/NeuraSleepService'));
await mkdir(join(output,'Contents/Library/LaunchDaemons'),{recursive:true});
await copyFile(join(native,'Support/app.neuraos.native.sleep.plist'),join(output,'Contents/Library/LaunchDaemons/app.neuraos.native.sleep.plist'));
// Preserve symbols outside the app so crash UUID/offsets can be decoded per build.
await rm(`${output}.dSYM`,{recursive:true,force:true});
execFileSync('dsymutil',[join(output,'Contents/MacOS/NeuraOS'),'-o',`${output}.dSYM`],{stdio:'inherit'});
const resourceRoot=join(native,'.build/release');
for(const file of await readdir(resourceRoot))if(file.endsWith('.bundle'))await cp(join(resourceRoot,file),join(output,'Contents/Resources',file),{recursive:true});
await mkdir(join(output,'Contents/Resources/Licenses'),{recursive:true});
// SwiftPM's checkout files can be read-only; replace the previous copied license.
for(const [name,source] of [
  ['SwiftTerm','SwiftTerm/LICENSE'],
  ['MarkdownUI','swift-markdown-ui/LICENSE'],
  ['NetworkImage','NetworkImage/LICENSE'],
  ['cmark-gfm','swift-cmark/COPYING'],
]) {
  const destination=join(output,'Contents/Resources/Licenses',`${name}.txt`);
  await rm(destination,{force:true});
  await copyFile(join(native,'.build/checkouts',source),destination);
}
await cp(join(root,'scripts/native/release/update.mjs'),join(output,'Contents/Resources/update.mjs'));
const bundleId=process.env.NEURA_APP_ID??'app.neuraos.native';
const extra=(process.env.NEURA_DEV_DATA_DIR?`<key>NeuraDataDirectory</key><string>${escape(process.env.NEURA_DEV_DATA_DIR)}</string>`:'')+(process.env.NEURA_DEV_PORT?`<key>NeuraEndpoint</key><string>http://127.0.0.1:${Number(process.env.NEURA_DEV_PORT)}</string>`:'');
await writeFile(join(output,'Contents/Info.plist'),`<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleExecutable</key><string>NeuraOS</string><key>CFBundleIdentifier</key><string>${escape(bundleId)}</string><key>CFBundleName</key><string>neuraOS</string><key>CFBundleDisplayName</key><string>neuraOS</string><key>CFBundleIconFile</key><string>AppIcon</string><key>CFBundlePackageType</key><string>APPL</string><key>CFBundleShortVersionString</key><string>${escape(version)}</string><key>CFBundleVersion</key><string>${build}</string><key>LSMinimumSystemVersion</key><string>14.0</string><key>NSHighResolutionCapable</key><true/><key>NSBluetoothAlwaysUsageDescription</key><string>neuraOS uses Bluetooth when websites use nearby devices for sign-in, such as passkeys on your phone.</string><key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/><key>NSAllowsArbitraryLoadsInWebContent</key><true/></dict>${extra}</dict></plist>`);
await bundleChromium(output,bundleId);
signApplication(output);
console.log(output);
