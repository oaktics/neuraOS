import {execFileSync} from 'node:child_process';
import {createHash} from 'node:crypto';
import {mkdir,readFile,writeFile,rm,rename,access} from 'node:fs/promises';
import {createReadStream} from 'node:fs';
import {resolve,join} from 'node:path';
import {fileURLToPath} from 'node:url';
const root=resolve(import.meta.dirname,'../../..');
export const cefRoot=join(root,'apps/macos/.cef');
export async function prepareChromium(){
  if(process.platform!=='darwin')return;
  const versions=JSON.parse(await readFile(join(import.meta.dirname,'version.json'),'utf8'));
  const version=versions[process.arch];
  if(!version)throw new Error(`Unsupported Chromium architecture: ${process.arch}`);
  const stamp=JSON.stringify(version);
  try{if(await readFile(join(cefRoot,'version.json'),'utf8')===stamp){await access(join(cefRoot,'sdk/include/cef_version.h'));return;}}catch{}
  await mkdir(cefRoot,{recursive:true});
  const archive=join(cefRoot,'sdk.tar.bz2');
  async function valid(){try{const hash=createHash('sha1');for await(const chunk of createReadStream(archive))hash.update(chunk);return hash.digest('hex')===version.sha1;}catch{return false;}}
  if(!await valid())execFileSync('curl',['--fail','--location','--retry','3',`https://cef-builds.spotifycdn.com/${encodeURIComponent(version.name)}`,'--output',archive],{stdio:'inherit'});
  // CEF's official index publishes SHA-1; pin it rather than trusting a moving download.
  if(!await valid())throw new Error('CEF archive checksum mismatch');
  const staging=join(cefRoot,'extract');
  await rm(staging,{recursive:true,force:true});await mkdir(staging,{recursive:true});
  execFileSync('tar',['-xjf',archive,'--strip-components=1','-C',staging],{stdio:'inherit'});
  await rm(join(cefRoot,'sdk'),{recursive:true,force:true});await rename(staging,join(cefRoot,'sdk'));
  await writeFile(join(cefRoot,'version.json'),stamp);
}
if(process.argv[1]===fileURLToPath(import.meta.url))await prepareChromium();
