import {execFileSync} from 'node:child_process';
import {mkdir,cp,writeFile,rm,copyFile} from 'node:fs/promises';
import {join} from 'node:path';
import {cefRoot,prepareChromium} from './prepare.mjs';
export async function bundleChromium(app,bundleId){
  await prepareChromium();
  const sdk=join(cefRoot,'sdk'),frameworks=join(app,'Contents/Frameworks');
  await mkdir(frameworks,{recursive:true});
  const framework=join(frameworks,'Chromium Embedded Framework.framework');
  await rm(framework,{recursive:true,force:true});
  // Preserve relative framework links so the app remains portable outside the build machine.
  await cp(join(sdk,'Release/Chromium Embedded Framework.framework'),framework,{recursive:true,verbatimSymlinks:true});
  const helper=join(cefRoot,'NeuraOS Helper');
  execFileSync('xcrun',['clang++','-std=c++20','-fobjc-arc','-mmacosx-version-min=14.0','-I',sdk,join(import.meta.dirname,'helper.mm'),'-framework','Foundation','-o',helper],{stdio:'inherit'});
  for(const [suffix,id] of [['',''],[' (Renderer)','.renderer'],[' (GPU)','.gpu'],[' (Plugin)','.plugin'],[' (Alerts)','.alerts']]){
    const name=`NeuraOS Helper${suffix}`,path=join(frameworks,`${name}.app`);
    await mkdir(join(path,'Contents/MacOS'),{recursive:true});
    await copyFile(helper,join(path,'Contents/MacOS',name));
    await writeFile(join(path,'Contents/Info.plist'),`<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleExecutable</key><string>${name}</string><key>CFBundleIdentifier</key><string>${bundleId}.helper${id}</string><key>CFBundleName</key><string>${name}</string><key>CFBundlePackageType</key><string>APPL</string><key>LSUIElement</key><true/><key>LSMinimumSystemVersion</key><string>14.0</string><key>NSHighResolutionCapable</key><true/></dict></plist>`);
  }
  await copyFile(join(sdk,'LICENSE.txt'),join(app,'Contents/Resources/Licenses/CEF.txt'));
  await copyFile(join(sdk,'CREDITS.html'),join(app,'Contents/Resources/Licenses/Chromium-CREDITS.html'));
  await copyFile(join(import.meta.dirname,'version.json'),join(app,'Contents/Resources/chromium-version.json'));
}
