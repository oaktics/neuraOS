import {execFileSync} from 'node:child_process';
import {mkdir,readFile,rm,rename,symlink,mkdtemp,realpath,lstat} from 'node:fs/promises';
import {homedir} from 'node:os';
import {resolve,join} from 'node:path';
import {fileURLToPath} from 'node:url';
import {cachedSDK} from './cache.mjs';
const root=resolve(import.meta.dirname,'../../..');
export const cefRoot=join(root,'apps/macos/.cef');
export async function prepareChromium(){
  if(process.platform!=='darwin')return;
  const versions=JSON.parse(await readFile(join(import.meta.dirname,'version.json'),'utf8'));
  const version=versions[process.arch];
  if(!version)throw new Error(`Unsupported Chromium architecture: ${process.arch}`);
  const cacheRoot=resolve(process.env.NEURA_CEF_CACHE_DIR??join(homedir(),'Library/Caches/neuraOS/cef'));
  const sdk=await cachedSDK({cacheRoot,arch:process.arch,version,download:async archive=>{
    execFileSync('curl',['--fail','--location','--retry','3',`https://cef-builds.spotifycdn.com/${encodeURIComponent(version.name)}`,'--output',archive],{stdio:'inherit'});
  }});
  await mkdir(cefRoot,{recursive:true});
  const local=join(cefRoot,'sdk');
  try {if(await realpath(local)===sdk)return;} catch {}
  const temporary=await mkdtemp(join(cefRoot,'.link-'));
  try {
    await symlink(sdk,join(temporary,'sdk'));
    // Old checkouts contain a generated SDK directory instead of a link.
    let existing;
    try {existing=await lstat(local);} catch(error) {if(error.code!=='ENOENT')throw error;}
    if(existing && !existing.isSymbolicLink())await rm(local,{recursive:true,force:true});
    await rename(join(temporary,'sdk'),local);
  } finally {await rm(temporary,{recursive:true,force:true});}
}
if(process.argv[1]===fileURLToPath(import.meta.url))await prepareChromium();
