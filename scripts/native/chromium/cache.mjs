import {execFileSync} from 'node:child_process';
import {createHash} from 'node:crypto';
import {createReadStream} from 'node:fs';
import {access,mkdir,mkdtemp,readFile,rename,rm,writeFile} from 'node:fs/promises';
import {join} from 'node:path';

// Publish only complete SDKs. Concurrent initial preparations may download twice,
// but never expose partial files or replace an SDK another build is using.
export async function cachedSDK({cacheRoot,arch,version,download}) {
  const destination=join(cacheRoot,`${arch}-${version.sha1}`),stamp=JSON.stringify(version);
  async function ready() {
    try {
      if(await readFile(join(destination,'version.json'),'utf8')!==stamp)return false;
      await access(join(destination,'sdk/include/cef_version.h'));
      await access(join(destination,'sdk/include/capi/cef_app_capi.h'));
      return true;
    } catch {return false;}
  }
  if(await ready())return join(destination,'sdk');
  await mkdir(cacheRoot,{recursive:true});
  const temporary=await mkdtemp(join(cacheRoot,'.prepare-'));
  try {
    const archive=join(temporary,'sdk.tar.bz2');
    await download(archive);
    const hash=createHash('sha1');
    for await(const chunk of createReadStream(archive))hash.update(chunk);
    if(hash.digest('hex')!==version.sha1)throw new Error('CEF archive checksum mismatch');
    const sdk=join(temporary,'sdk');
    await mkdir(sdk);
    execFileSync('tar',['-xjf',archive,'--strip-components=1','-C',sdk],{stdio:'inherit'});
    await access(join(sdk,'include/cef_version.h'));
    await access(join(sdk,'include/capi/cef_app_capi.h'));
    await writeFile(join(temporary,'version.json'),stamp);
    try {await rename(temporary,destination);} catch(error) {
      if(!await ready())throw error;
    }
    return join(destination,'sdk');
  } finally {await rm(temporary,{recursive:true,force:true});}
}
