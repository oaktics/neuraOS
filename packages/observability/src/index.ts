import { trace, SpanStatusCode } from '@opentelemetry/api';
export async function traced<T>(name:string,attributes:Record<string,string>,fn:()=>Promise<T>):Promise<T>{
  return trace.getTracer('neuraos','0.1.0').startActiveSpan(name,{attributes},async span=>{try{return await fn();}catch(e){span.setStatus({code:SpanStatusCode.ERROR,message:e instanceof Error?e.name:'error'});throw e;}finally{span.end();}});
}
export function log(event:string,fields:Record<string,string|number|boolean|null>={}){
  // Only allow identifiers, counters, and reason codes. Never log prompts, tokens, or headers.
  const allowed=new Set(['taskId','runId','actionId','operationId','code','durationMs','count','mode']);
  process.stdout.write(JSON.stringify({at:new Date().toISOString(),event,...Object.fromEntries(Object.entries(fields).filter(([k])=>allowed.has(k)))})+'\n');
}
