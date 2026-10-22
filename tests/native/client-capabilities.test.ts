import {test} from 'node:test';
import assert from 'node:assert/strict';
import {execFile} from 'node:child_process';
import {promisify} from 'node:util';
import {mkdtemp,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join,resolve} from 'node:path';

const exec=promisify(execFile);
test('native client decodes legacy v1 and gates GitHub on advertised features',{skip:process.platform!=='darwin',timeout:120000},async()=>{
  const dir=await mkdtemp(join(tmpdir(),'neura-capabilities-'));
  try {
    const binary=join(dir,'capabilities');
    await exec('xcrun',['swiftc','-swift-version','5','-parse-as-library',
      resolve('apps/macos/Sources/NeuraOS/Models.swift'),
      resolve('apps/macos/Sources/NeuraOS/SidebarSpaces.swift'),
      resolve('tests/native/fixtures/daemon-capabilities.swift'),'-o',binary],{timeout:90000});
    const {stdout}=await exec(binary,[],{timeout:10000});
    assert.match(stdout,/Legacy and current daemon feature contracts passed/);
  } finally {await rm(dir,{recursive:true,force:true});}
});
