import {mkdir,rm,copyFile,chmod,readdir,lstat} from 'node:fs/promises';
import {join} from 'node:path';
import {isMachO} from '../signing/sign.mjs';
export const runtimeExecutables=['neura-native-core','neura-updater'];
export async function assertNativeRuntime(runtime){
 const entries=await readdir(runtime);
 if(entries.length!==1||entries[0]!=='bin')throw Error('Runtime must contain only native executables in bin/');
 const names=(await readdir(join(runtime,'bin'))).sort();
 if(JSON.stringify(names)!==JSON.stringify([...runtimeExecutables].sort()))throw Error('Unexpected Runtime executable or dependency');
 for(const name of names){const file=join(runtime,'bin',name),info=await lstat(file);if(!info.isFile()||!(info.mode&0o111)||!isMachO(file))throw Error(`Runtime executable is not native Mach-O: ${name}`);}
}
export async function packageNativeRuntime(app,daemon,updater){
 for(const source of [daemon,updater])if(!(await lstat(source)).isFile()||!isMachO(source))throw Error(`Native build required: ${source}`);
 const runtime=join(app,'Contents/Resources/Runtime');
 await rm(runtime,{recursive:true,force:true});await mkdir(join(runtime,'bin'),{recursive:true});
 for(const [name,source] of [['neura-native-core',daemon],['neura-updater',updater]]){await copyFile(source,join(runtime,'bin',name));await chmod(join(runtime,'bin',name),0o755);}
 // Remove the updater shipped by older development builds too.
 await rm(join(app,'Contents/Resources/update.mjs'),{force:true});
 await assertNativeRuntime(runtime);
}
