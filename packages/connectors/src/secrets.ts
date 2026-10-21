import { execFile, spawn } from 'node:child_process';
import { promisify } from 'node:util';
import { DomainError } from '../../policy/src/index.ts';
const exec=promisify(execFile);
export async function readSecret(name:string):Promise<string|null>{
  if(process.platform!=='darwin')throw new DomainError('keychain_platform_unsupported');
  try{const {stdout}=await exec('/usr/bin/security',['find-generic-password','-s','app.neuraos','-a',name,'-w'],{maxBuffer:65536});return stdout.trim()||null;}catch{return null;}
}
// Secrets are provisioned through native Keychain commands; never through model context or logs.
export async function writeSecret(name:string,value:string):Promise<void>{
  if(process.platform!=='darwin')throw new DomainError('keychain_platform_unsupported');
  if(!/^[a-zA-Z0-9._-]+$/.test(name)||/[\r\n\0]/.test(value))throw new DomainError('invalid_secret');
  const quote=(s:string)=>'"'+s.replace(/\\/g,'\\\\').replace(/"/g,'\\"')+'"';
  await new Promise<void>((resolve,reject)=>{
    // Interactive stdin avoids putting credential values in the process argument list.
    const child=spawn('/usr/bin/security',['-i'],{stdio:['pipe','ignore','ignore']});
    child.on('error',()=>reject(new DomainError('keychain_write_failed')));child.on('exit',code=>code===0?resolve():reject(new DomainError('keychain_write_failed')));
    child.stdin.end(`add-generic-password -U -s app.neuraos -a ${quote(name)} -w ${quote(value)}\n`);
  });
  if(await readSecret(name)!==value)throw new DomainError('keychain_write_failed');
}
