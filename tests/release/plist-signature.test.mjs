import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtempSync,mkdirSync,writeFileSync,copyFileSync,rmSync} from 'node:fs';
import {join,resolve} from 'node:path';
import {tmpdir} from 'node:os';
import {execFileSync} from 'node:child_process';
import {signApplication} from '../../scripts/native/signing/sign.mjs';

test('main and nested helpers pass Chromium dynamic plist validation after canonical signing', {skip:process.platform!=='darwin'}, t=>{
 const root=mkdtempSync(join(tmpdir(),'neura-plist-signature-'));
 t.after(()=>{if(process.env.NEURA_KEEP_SIGNING_FIXTURE!=='1')rmSync(root,{recursive:true,force:true});});
 const executable=join(root,'probe');
 execFileSync('xcrun',['clang','-fobjc-arc','-framework','Foundation','-framework','Security',resolve('tests/fixtures/signing/dynamic-plist.m'),'-o',executable]);
 const app=join(root,'Probe.app');
 const bundles=[app,join(app,'Contents/Frameworks/NeuraOS Helper.app'),join(app,'Contents/Frameworks/NeuraOS Helper (Renderer).app')];
 for(const [index,bundle] of bundles.entries()){
  mkdirSync(join(bundle,'Contents/MacOS'),{recursive:true});copyFileSync(executable,join(bundle,'Contents/MacOS/probe'));
  writeFileSync(join(bundle,'Contents/Info.plist'),`<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleExecutable</key><string>probe</string><key>CFBundleIdentifier</key><string>com.neuraos.plist-fixture.${index}</string><key>CFBundleName</key><string>Probe &amp; Fixture</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>`);
 }
 const run=bundle=>JSON.parse(execFileSync(join(bundle,'Contents/MacOS/probe'),[],{encoding:'utf8'}));
 // Prove the fixture detects the original bug, rather than a vacuous signature pass.
 execFileSync('codesign',['--force','--deep','--sign','-',app],{stdio:'pipe'});
 const before=run(app);assert.equal(before.equalBytes,false);assert.equal(before.dynamicValidity,-67030);
 signApplication(app,process.env.NEURA_PLIST_TEST_IDENTITY??'-');
 execFileSync('codesign',['--verify','--deep','--strict',app],{stdio:'pipe'});
 for(const bundle of bundles){const result=run(bundle);assert.equal(result.equalBytes,true,bundle);assert.equal(result.dynamicValidity,0,bundle);assert.equal(result.chromiumValidity,0,bundle);console.log(JSON.stringify({bundle,...result}));}
});
