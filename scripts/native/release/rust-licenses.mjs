import {execFileSync} from 'node:child_process';
import {mkdir,readdir,copyFile,rm,writeFile} from 'node:fs/promises';
import {join,dirname} from 'node:path';
import {homedir} from 'node:os';
import {existsSync} from 'node:fs';
export async function bundleRustLicenses(root,app){
 const local=join(homedir(),'.cargo/bin/cargo'),cargo=existsSync(local)?local:'cargo';
 const metadata=JSON.parse(execFileSync(cargo,['metadata','--locked','--format-version','1','--manifest-path',join(root,'crates/native-core/Cargo.toml')],{encoding:'utf8',maxBuffer:16*1024*1024}));
 const destination=join(app,'Contents/Resources/Licenses/Rust');await rm(destination,{recursive:true,force:true});await mkdir(destination,{recursive:true});
 const notices=[];
 for(const pkg of metadata.packages.filter(p=>p.source)){
  const directory=dirname(pkg.manifest_path),out=join(destination,`${pkg.name}-${pkg.version}`);
  const files=(await readdir(directory,{withFileTypes:true})).filter(f=>f.isFile()&&/^(licen[sc]e|copying|copyright|notice)([._-].*)?$/i.test(f.name));
  await mkdir(out,{recursive:true});
  for(const file of files)await copyFile(join(directory,file.name),join(out,file.name));
  notices.push({name:pkg.name,version:pkg.version,license:pkg.license,repository:pkg.repository});
 }
 await writeFile(join(destination,'packages.json'),JSON.stringify(notices,null,2));
}
