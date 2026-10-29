import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtemp,mkdir,writeFile,readFile,rm,symlink,readdir} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {packageNativeRuntime,assertNativeRuntime} from '../../scripts/native/release/native-runtime.mjs';
test('packaging replaces Node/tsx/dependencies with only two native executables',async t=>{
 const dir=await mkdtemp(join(tmpdir(),'neura-package-native-'));t.after(()=>rm(dir,{recursive:true,force:true}));
 const app=join(dir,'app'),runtime=join(app,'Contents/Resources/Runtime');await mkdir(join(runtime,'node_modules/tsx'),{recursive:true});
 await writeFile(join(app,'Contents/Resources/update.mjs'),'legacy');
 const daemon=join(dir,'daemon'),updater=join(dir,'updater');
 for(const file of [daemon,updater])await writeFile(file,Buffer.from('cffaedfe00000000','hex'));
 await packageNativeRuntime(app,daemon,updater);await assertNativeRuntime(runtime);
 assert.deepEqual((await readdir(join(runtime,'bin'))).sort(),['neura-native-core','neura-updater']);
 await assert.rejects(readFile(join(app,'Contents/Resources/update.mjs')),/ENOENT/);
 await writeFile(join(runtime,'bin/node'),'unexpected');await assert.rejects(assertNativeRuntime(runtime));
 await rm(join(runtime,'bin/node'));await rm(join(runtime,'bin/neura-updater'));await symlink(updater,join(runtime,'bin/neura-updater'));await assert.rejects(assertNativeRuntime(runtime));
});
test('invalid native build is rejected before replacing a prior runtime',async t=>{
 const dir=await mkdtemp(join(tmpdir(),'neura-package-invalid-'));t.after(()=>rm(dir,{recursive:true,force:true}));
 const app=join(dir,'app'),runtime=join(app,'Contents/Resources/Runtime');await mkdir(runtime,{recursive:true});await writeFile(join(runtime,'keep'),'old');
 const script=join(dir,'daemon');await writeFile(script,'#!/bin/sh\n');
 await assert.rejects(packageNativeRuntime(app,script,script),/Native build required/);assert.equal(await readFile(join(runtime,'keep'),'utf8'),'old');
});
