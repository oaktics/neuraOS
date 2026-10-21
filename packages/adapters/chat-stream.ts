import {parsePartialJson} from 'ai';
import type {AdapterContext} from './index.ts';
/** Expose only the public reply field. Never stream reasoning, tool arguments or credentials. */
export function chatTextEmitter(context:AdapterContext){
 const enabled=!!context.onText&&['vice_president','director_chat'].includes(context.task.work?.role??'');let latest='',timer:NodeJS.Timeout|undefined,chain=Promise.resolve(),sent='';
 const flush=async()=>{if(timer){clearTimeout(timer);timer=undefined;}if(!enabled)return;const input=latest;chain=chain.then(async()=>{const outer=(await parsePartialJson(input)).value as any;const content=outer?.artifacts?.find((a:any)=>a?.name==='response.json')?.content;if(typeof content!=='string')return;const reply=(await parsePartialJson(content)).value as any;if(typeof reply?.reply==='string'&&reply.reply.startsWith(sent)&&reply.reply.length>sent.length){sent=reply.reply;await context.onText!(sent);}}).catch(()=>{});await chain;};
 return {push(value:string){latest=value;if(enabled&&!timer)timer=setTimeout(()=>void flush(),75);},flush};
}
