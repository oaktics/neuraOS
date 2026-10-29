import {test} from 'node:test';
import assert from 'node:assert/strict';
import {execFile} from 'node:child_process';
import {promisify} from 'node:util';
import {mkdtemp,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join,resolve} from 'node:path';

const exec=promisify(execFile);
test('native client decodes legacy v1 and gates GitHub on advertised features',{skip:process.platform!=='darwin',timeout:210000},async()=>{
  const dir=await mkdtemp(join(tmpdir(),'neura-capabilities-'));
  try {
    const binary=join(dir,'capabilities');
    await exec('xcrun',['swiftc','-swift-version','5','-emit-library','-emit-module','-module-name','SleepControl',
      resolve('apps/macos/Sources/SleepControl/SleepLease.swift'),
      resolve('apps/macos/Sources/SleepControl/SleepService.swift'),
      resolve('apps/macos/Sources/SleepControl/SleepSession.swift'),
      '-emit-module-path',join(dir,'SleepControl.swiftmodule'),'-o',join(dir,'libSleepControl.dylib')],{timeout:180000});
    // Fresh macOS runners may need over 90s to compile Swift SDK modules.
    // Keep the executable timeout separate so contract failures still fail quickly.
    await exec('xcrun',['swiftc','-swift-version','5','-parse-as-library','-I',dir,'-L',dir,'-lSleepControl','-Xlinker','-rpath','-Xlinker',dir,
      resolve('apps/macos/Sources/NeuraOS/Models.swift'),
      resolve('apps/macos/Sources/NeuraOS/DaemonEvents.swift'),
      resolve('apps/macos/Sources/NeuraOS/Diagnostics.swift'),
      resolve('apps/macos/Sources/NeuraOS/AgentNotifications.swift'),
      resolve('apps/macos/Sources/NeuraOS/AgentSleep.swift'),
      resolve('apps/macos/Sources/NeuraOS/SleepServiceRegistration.swift'),
      resolve('apps/macos/Sources/NeuraOS/SidebarSpaces.swift'),
      resolve('apps/macos/Sources/NeuraOS/AgentActivity.swift'),
      resolve('tests/native/fixtures/daemon-capabilities.swift'),'-o',binary],{timeout:180000});
    const {stdout}=await exec(binary,[],{timeout:10000});
    assert.match(stdout,/Legacy and current daemon feature contracts passed/);
  } finally {await rm(dir,{recursive:true,force:true});}
});
