import {execFileSync} from 'node:child_process';
import {mkdir,cp,writeFile,copyFile,rm,readdir} from 'node:fs/promises';
import {resolve,join} from 'node:path';
const root=resolve(import.meta.dirname,'../..'),native=join(root,'apps/macos');
const output=process.env.NEURA_APP_OUTPUT??join(native,'dist/neuraOS.app');
const escape=value=>value.replaceAll('&','&amp;').replaceAll('<','&lt;').replaceAll('>','&gt;');
execFileSync('swift',['build','--package-path',native,'-c','release','--force-resolved-versions',...(process.env.NEURA_SWIFT_BUILD_SYSTEM?['--build-system',process.env.NEURA_SWIFT_BUILD_SYSTEM]:[])],{stdio:'inherit'});
await mkdir(join(output,'Contents/MacOS'),{recursive:true});
await mkdir(join(output,'Contents/Resources'),{recursive:true});
await rm(join(output,'Contents/Resources/Terminal'),{recursive:true,force:true});
await copyFile(join(native,'.build/release/NeuraOS'),join(output,'Contents/MacOS/NeuraOS'));
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
const bundleId=process.env.NEURA_APP_ID??'app.neuraos.native';
const extra=(process.env.NEURA_DEV_DATA_DIR?`<key>NeuraDataDirectory</key><string>${escape(process.env.NEURA_DEV_DATA_DIR)}</string>`:'')+(process.env.NEURA_DEV_PORT?`<key>NeuraEndpoint</key><string>http://127.0.0.1:${Number(process.env.NEURA_DEV_PORT)}</string>`:'');
await writeFile(join(output,'Contents/Info.plist'),`<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleExecutable</key><string>NeuraOS</string><key>CFBundleIdentifier</key><string>${escape(bundleId)}</string><key>CFBundleName</key><string>neuraOS</string><key>CFBundleDisplayName</key><string>neuraOS</string><key>CFBundlePackageType</key><string>APPL</string><key>CFBundleShortVersionString</key><string>0.2.0</string><key>CFBundleVersion</key><string>2</string><key>LSMinimumSystemVersion</key><string>14.0</string><key>NSHighResolutionCapable</key><true/><key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/><key>NSAllowsArbitraryLoadsInWebContent</key><true/></dict>${extra}</dict></plist>`);
execFileSync('codesign',['--force','--deep','--sign','-',output],{stdio:'inherit'});
console.log(output);
