import {test} from 'node:test';
import assert from 'node:assert/strict';
import {CodexTitles} from '../../apps/daemon/src/codex-titles.ts';
import type {CodexRPC} from '../../apps/daemon/src/codex-rpc.ts';

function fixture(options:{manual?:boolean;renamed?:boolean;stale?:boolean;failed?:boolean;unsafe?:boolean}={}){
  const titles=new CodexTitles(),calls:{method:string;params:any}[]=[];
  let reads=0,current=true;
  const rpc={async call(method:string,params:any){
    calls.push({method,params});
    if(method==='thread/read')return {thread:{name:options.manual||(++reads>1&&options.renamed)?'Manual':null,preview:'ユーザー依頼'}};
    if(method==='config/read')return {config:{mcp_servers:{neuraos:{command:'node',args:['supervision-mcp.mjs'],tool_timeout_sec:null},other:{url:'https://example.invalid/mcp'}}}};
    if(method==='thread/start')return {thread:{id:'temporary'},sandbox:{type:options.unsafe?'dangerFullAccess':'readOnly'}};
    if(method==='turn/start'){
      current=!options.stale;
      titles.event({method:'item/completed',params:{threadId:'temporary',item:{type:'agentMessage',text:'{"title":"生成タイトル"}'}}});
      titles.event({method:'turn/completed',params:{threadId:'temporary',turn:{status:options.failed?'failed':'completed'}}});
    }
    return {};
  }} as unknown as CodexRPC;
  return {titles,calls,run:()=>titles.generate(rpc,'main','/repo',()=>current)};
}
test('remote titles use isolated tool-free ephemeral turns and persist through the official name API',async()=>{
  const f=fixture();await f.run();await f.run();
  assert.equal(f.calls.filter(c=>c.method==='thread/start').length,1);
  const params=f.calls.find(c=>c.method==='thread/start')!.params;
  assert.equal(params.ephemeral,true);assert.equal(params.sandbox,'read-only');
  assert.deepEqual(params.config.mcp_servers,{neuraos:{command:'node',enabled:false},other:{url:'https://example.invalid/mcp',enabled:false}});
  assert.equal(params.config['features.shell_tool'],false);assert.equal(params.config['features.hooks'],false);
  assert.deepEqual(f.calls.find(c=>c.method==='thread/name/set')?.params,{threadId:'main',name:'生成タイトル'});
  assert.equal(f.calls.at(-1)?.method,'thread/unsubscribe');
});
test('manual names, rename races, switched sessions, failures and unsafe permissions never apply generated titles',async()=>{
  for(const options of [{manual:true},{renamed:true},{stale:true},{failed:true},{unsafe:true}]){
    const f=fixture(options);await f.run();assert.equal(f.calls.some(c=>c.method==='thread/name/set'),false,JSON.stringify(options));
    if(options.manual)assert.equal(f.calls.length,1);
    if(options.unsafe)assert.equal(f.calls.some(c=>c.method==='turn/start'),false);
  }
});
