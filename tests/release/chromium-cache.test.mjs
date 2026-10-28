import test from 'node:test';
import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {createHash} from 'node:crypto';
import {mkdtemp,mkdir,writeFile,readFile,copyFile,rm,realpath,readdir} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {cachedSDK} from '../../scripts/native/chromium/cache.mjs';

test('CEF cache verifies archives, reuses SDKs, separates architectures and publishes concurrently',async()=>{
  const root=await mkdtemp(join(tmpdir(),'neura-cef-test-'));
  try {
    const fixture=join(root,'fixture');
    await mkdir(join(fixture,'include/capi'),{recursive:true});
    await writeFile(join(fixture,'include/cef_version.h'),'version');
    await writeFile(join(fixture,'include/capi/cef_app_capi.h'),'api');
    const archive=join(root,'fixture.tar.bz2');
    execFileSync('tar',['-cjf',archive,'-C',root,'fixture']);
    const version={name:'fixture',sha1:createHash('sha1').update(await readFile(archive)).digest('hex')};
    const cacheRoot=join(root,'cache');
    let downloads=0;
    const download=async target=>{downloads++;await copyFile(archive,target);};
    const options={cacheRoot,arch:'arm64',version,download};
    const [one,two]=await Promise.all([cachedSDK(options),cachedSDK(options)]);
    assert.equal(await realpath(one),await realpath(two));
    assert.equal(await readFile(join(one,'include/capi/cef_app_capi.h'),'utf8'),'api');
    const count=downloads;
    assert.equal(await cachedSDK(options),one);
    assert.equal(downloads,count);
    assert.notEqual(await cachedSDK({...options,arch:'x64'}),one);
    await assert.rejects(cachedSDK({...options,version:{...version,sha1:'0'.repeat(40)}}),/checksum mismatch/);
    assert.equal((await readdir(cacheRoot)).some(name=>name.startsWith('.prepare-')),false);
    assert.equal((await readdir(cacheRoot)).length,2);
  } finally {await rm(root,{recursive:true,force:true});}
});
