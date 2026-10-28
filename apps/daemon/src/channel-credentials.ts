import {randomBytes,timingSafeEqual} from 'node:crypto';

// Issued only inside the daemon at terminal launch. Possession of the general
// task-MCP bearer does not let a sibling mint or derive a channel capability.
const credentials=new Map<string,string>();
export async function channelCredential(tokenPath:string,terminalId:string){
  const key=tokenPath+':'+terminalId;
  let credential=credentials.get(key);
  if(!credential){credential=randomBytes(32).toString('hex');credentials.set(key,credential);}
  return credential;
}
export async function validChannelCredential(tokenPath:string,terminalId:string,supplied:unknown){
  const expected=credentials.get(tokenPath+':'+terminalId);
  return !!expected&&typeof supplied==='string'&&/^[a-f0-9]{64}$/.test(supplied)&&timingSafeEqual(Buffer.from(supplied),Buffer.from(expected));
}
export function revokeChannelCredential(tokenPath:string,terminalId:string){credentials.delete(tokenPath+':'+terminalId);}
