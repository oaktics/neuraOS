import {randomBytes,timingSafeEqual} from 'node:crypto';
// Issued only in the daemon process while launching a CLI. The shared task-MCP
// bearer cannot derive or mint a browser capability through any HTTP endpoint.
// Restarting the daemon revokes these in-memory, terminal-scoped credentials.
const credentials=new Map<string,string>();
export function issueBrowserCredential(terminalId:string){
 let value=credentials.get(terminalId);if(!value){value=randomBytes(32).toString('hex');credentials.set(terminalId,value);}return value;
}
export async function browserCredential(_tokenPath:string,terminalId:string){return issueBrowserCredential(terminalId);}
export function verifyBrowserCredential(_master:string,terminalId:string,credential:unknown){
 const expected=credentials.get(terminalId);
 if(!expected||typeof credential!=='string'||! /^[a-f0-9]{64}$/.test(credential))return false;
 return timingSafeEqual(Buffer.from(credential),Buffer.from(expected));
}
