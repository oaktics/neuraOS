import {TokenMeter} from './token-budget.ts';
import { createServer, type Server } from 'node:http';
import type {ProviderAuth} from './local-auth.ts';
import { ensure } from '../policy/src/index.ts';
/** Only inference endpoints are reachable; credentials stay in the parent process. */
export async function inferenceProxy(provider:'codex'|'claude',key:string,callLimit=1,auth?:ProviderAuth,options?:{tokens:number;requestFetch?:typeof fetch}){
  let calls=0,tokens=0,measuredCalls=0,budgetExceeded=false,inFlight=false;
  const upstream=provider==='codex'?(auth?.kind==='chatgpt'?'https://chatgpt.com/backend-api/codex':'https://api.openai.com'):'https://api.anthropic.com';
  const paths=provider==='codex'?new Set(['/v1/responses','/v1/models']):new Set(['/v1/messages','/v1/messages/count_tokens']);
  const server=createServer(async(req,res)=>{
    const url=new URL(req.url??'/',`http://127.0.0.1`);
    const allowedQuery=!url.search||(provider==='claude'&&url.search==='?beta=true');
    if(!paths.has(url.pathname)||!allowedQuery||!['GET','POST'].includes(req.method??'')){res.writeHead(403).end();return;}
    try{
      const chunks:Buffer[]=[];let size=0;for await(const chunk of req){size+=chunk.length;ensure(size<8*1024*1024,'request_too_large');chunks.push(chunk);}
      const inference=req.method==='POST'&&['/v1/responses','/v1/messages'].includes(url.pathname);
      const headers:Record<string,string>={'content-type':'application/json'};
      if(inference){
        if(calls>=callLimit){res.writeHead(429,{'content-type':'application/json'}).end(JSON.stringify({error:{type:'budget_exceeded',message:'neuraOS model-call budget exhausted'}}));return;}
        // Estimate admission, then use measured usage before another call. One in-flight
        // response can exceed its estimate; this is not a provider-enforced hard cap.
        if(options&&(inFlight||measuredCalls<calls||tokens+Math.ceil(size/3)+6000>options.tokens)){budgetExceeded=true;res.writeHead(429,{'content-type':'application/json'}).end(JSON.stringify({error:{type:'budget_exceeded',message:'neuraOS token budget exhausted'}}));return;}calls++;inFlight=true;
      }
      if(provider==='codex'){headers.authorization=`Bearer ${key}`;if(auth?.accountId)headers['chatgpt-account-id']=auth.accountId;for(const name of ['openai-beta','originator','version','session_id','conversation_id'])if(typeof req.headers[name]==='string')headers[name]=req.headers[name];}
      else {if(auth?.kind==='claude-login')headers.authorization=`Bearer ${key}`;else headers['x-api-key']=key;headers['anthropic-version']='2023-06-01';if(typeof req.headers['anthropic-beta']==='string')headers['anthropic-beta']=req.headers['anthropic-beta'];}
      const abort=new AbortController();res.on('close',()=>abort.abort());
      const targetPath=auth?.kind==='chatgpt'?url.pathname.replace(/^\/v1/,''):url.pathname;
      const response=await (options?.requestFetch??fetch)(upstream+targetPath+url.search,{method:req.method,headers,body:req.method==='POST'?Buffer.concat(chunks):undefined,signal:abort.signal,redirect:'error'});
      res.writeHead(response.status,{'content-type':response.headers.get('content-type')??'application/json'});
      const meter=new TokenMeter(provider),json:Uint8Array[]=[];const streaming=response.headers.get('content-type')?.includes('text/event-stream');
      try{if(response.body)for await(const chunk of response.body){if(inference){if(streaming)meter.feed(chunk);else json.push(chunk);}res.write(chunk);}
       if(inference&&!streaming)try{meter.observe(JSON.parse(Buffer.concat(json).toString('utf8')));}catch{}
       if(inference&&meter.measured){tokens+=meter.tokens;measuredCalls++;}
      }finally{if(inference)inFlight=false;}res.end();
    }catch{if(!res.headersSent)res.writeHead(502);res.end();}
  });
  await new Promise<void>((resolve,reject)=>{server.once('error',reject);server.listen(0,'127.0.0.1',resolve);});
  const port=(server.address() as {port:number}).port;
  return {port,url:`http://127.0.0.1:${port}`,get calls(){return calls;},get tokens(){return tokens;},get measured(){return measuredCalls===calls;},get budgetExceeded(){return budgetExceeded;},close:async()=>{server.closeAllConnections();await new Promise<void>(resolve=>server.close(()=>resolve()));}};
}
