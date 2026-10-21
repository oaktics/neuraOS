import { lookup } from 'node:dns/promises';
import { isIP } from 'node:net';
import { request } from 'node:https';
import { randomUUID } from 'node:crypto';
import { ensure } from '../../policy/src/index.ts';
import type { Source } from '../../contracts/src/index.ts';
export function publicAddress(address:string):boolean{
  if(isIP(address)===4){const [a,b,c]=address.split('.').map(Number);return !(a===0||a===10||a===127||a===169&&b===254||a===172&&b>=16&&b<=31||a===192&&(b===168||b===0)||a===100&&b>=64&&b<=127||a>=224||a===198&&(b===18||b===19));}
  // IPv6 literals and mapped addresses are intentionally not accepted by this initial importer.
  return false;
}
export async function fetchPublicSource(value:string,redirects=0):Promise<Source>{
  const url=new URL(value);ensure(url.protocol==='https:'&&!url.username&&!url.password&&(!url.port||url.port==='443'),'source_url_denied');ensure(redirects<=3,'source_redirect_limit');
  const addresses=await lookup(url.hostname,{all:true,family:4});ensure(addresses.length>0&&addresses.every(a=>publicAddress(a.address)),'source_private_address');
  const {status,headers,body}=await new Promise<{status:number;headers:import('node:http').IncomingHttpHeaders;body:string}>((resolve,reject)=>{
    const req=request(url,{method:'GET',headers:{'User-Agent':'neuraOS-source-import/0.1.0',Accept:'text/html,text/plain,application/json','Accept-Encoding':'identity'},lookup:(_hostname,opts,callback)=>{const a=addresses[0];if((opts as {all?:boolean}).all)(callback as unknown as (err:null,values:{address:string;family:number}[])=>void)(null,[a]);else callback(null,a.address,a.family);}},res=>{
      const chunks:Buffer[]=[];let size=0;res.on('data',(chunk:Buffer)=>{size+=chunk.length;if(size>500000){req.destroy(new Error('source_too_large'));return;}chunks.push(chunk);});res.on('end',()=>resolve({status:res.statusCode??0,headers:res.headers,body:Buffer.concat(chunks).toString('utf8')}));res.on('error',reject);
    });req.setTimeout(15000,()=>req.destroy(new Error('source_timeout')));req.on('error',reject);req.end();
  });
  if(status>=300&&status<400&&headers.location)return fetchPublicSource(new URL(headers.location,url).toString(),redirects+1);
  ensure(status===200,'source_fetch_failed');ensure(/^(text\/(html|plain|markdown|csv)|application\/json)/i.test(headers['content-type']??''),'source_type_unsupported');
  const title=body.match(/<title[^>]*>([^<]*)<\/title>/i)?.[1]?.trim()||url.hostname;
  const content=(headers['content-type']??'').includes('text/html')?body.replace(/<(script|style)\b[^>]*>[\s\S]*?<\/\1>/gi,'').replace(/<[^>]*>/g,' ').replace(/[ \t]+/g,' ').trim():body;
  return {id:randomUUID(),title:title.slice(0,200),content,origin:'external',classification:'standard',url:url.toString(),retrievedAt:new Date().toISOString()};
}
