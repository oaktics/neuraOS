import {spawn} from 'node:child_process';
import {access, mkdir, copyFile} from 'node:fs/promises';
import {join,resolve} from 'node:path';
import {homedir} from 'node:os';
import {pathToFileURL} from 'node:url';
export async function buildNativeCore(){
 const root=resolve(import.meta.dirname,'../..');
 const local=join(homedir(),'.cargo/bin/cargo');
 const cargo=await access(local).then(()=>local,()=> 'cargo');
 await new Promise((resolve,reject)=>{const p=spawn(cargo,['build','--release','--locked','--jobs','2','--manifest-path',join(root,'crates/native-core/Cargo.toml')],{stdio:'inherit'});p.once('error',reject);p.once('exit',code=>code===0?resolve():reject(new Error('Native core build failed')));});
 await mkdir(join(root,'.native'),{recursive:true});
 await copyFile(join(root,'crates/native-core/target/release/neura-native-core'),join(root,'.native/neura-native-core'));
}
if(process.argv[1]&&import.meta.url===pathToFileURL(resolve(process.argv[1])).href)await buildNativeCore();
