import {test} from 'node:test';
import assert from 'node:assert/strict';
import {mkdtemp,writeFile,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {parseCodexUsage,parseClaudeUsage,readCodexUsage,readClaudeUsage,ProviderUsageService} from '../../apps/daemon/src/provider-usage.ts';
import {createDaemon} from '../../apps/daemon/src/server.ts';

test('quota parsers preserve zero, missing windows, actual durations and reset times',()=>{
  assert.deepEqual(parseCodexUsage({rateLimits:{primary:null,secondary:{usedPercent:30,windowDurationMins:10080,resetsAt:1793082918}}}),[
    {label:'週',usedPercent:30,resetsAt:'2026-10-27T06:35:18.000Z'},
  ]);
  assert.deepEqual(parseCodexUsage({rateLimitsByLimitId:{codex:{primary:{usedPercent:0,windowDurationMins:300}}},rateLimits:{primary:{usedPercent:99}}}),[
    {label:'5h',usedPercent:0,resetsAt:null},
  ]);
  assert.deepEqual(parseCodexUsage({rateLimits:{limitId:'another_model',primary:{usedPercent:42}}}),[]);
  assert.equal(parseCodexUsage({rateLimits:{primary:{usedPercent:5,windowDurationMins:15}}})[0].label,'15m');
  assert.deepEqual(parseClaudeUsage({five_hour:{utilization:0,resets_at:null},seven_day:null}),[{label:'5h',usedPercent:0,resetsAt:null}]);
  assert.equal(parseClaudeUsage({seven_day:{utilization:101,resets_at:'bad date'}})[0].resetsAt,null);
  for(const invalid of [-1,NaN,Infinity,'25'])assert.throws(()=>parseClaudeUsage({five_hour:{utilization:invalid}}));
  assert.throws(()=>parseCodexUsage({rateLimits:{primary:{usedPercent:'42'}}}));
});

test('Claude request is read-only, fixed-host, bounded and does not return credentials',async()=>{
  const windows=await readClaudeUsage(async()=>'test-secret',async(input,init)=>{
    assert.equal(input,'https://api.anthropic.com/api/oauth/usage');
    assert.equal(init?.redirect,'error');assert.ok(init?.signal);
    assert.equal(new Headers(init?.headers).get('authorization'),'Bearer test-secret');
    assert.equal(init?.method,undefined);
    return new Response(JSON.stringify({five_hour:{utilization:12},accessToken:'must-not-return'}));
  });
  assert.deepEqual(windows,[{label:'5h',usedPercent:12,resetsAt:null}]);
  const denied=new ProviderUsageService({codex:async()=>[],claude:()=>readClaudeUsage(async()=>'test-secret',async()=>new Response('secret error body',{status:401}))});
  const result=await denied.read();
  assert.equal(result[1].status,'signed_out');assert.ok(!JSON.stringify(result).includes('secret'));
});

test('usage cache coalesces reads, isolates provider failures, and discards old percentages on failure',async()=>{
  let calls=0,fail=false;
  const readers={codex:async()=>{calls++;if(fail)throw Error('private diagnostic');return [{label:'週',usedPercent:50,resetsAt:null}];},claude:async()=>{throw Error('secret');}};
  const cached=new ProviderUsageService(readers);
  const [a,b]=await Promise.all([cached.read(),cached.read()]);
  assert.deepEqual(a,b);await cached.read();assert.equal(calls,1);
  assert.equal(a[1].status,'unavailable');assert.deepEqual(a[1].windows,[]);
  assert.ok(!JSON.stringify(a).includes('secret'));
  const fresh=new ProviderUsageService(readers,0);
  assert.equal((await fresh.read())[0].status,'available');fail=true;
  const result=(await fresh.read())[0];assert.equal(result.status,'unavailable');assert.deepEqual(result.windows,[]);
});

test('Codex reader initializes, only requests quota, and cleans up its subprocess',async()=>{
  const dir=await mkdtemp(join(tmpdir(),'neura-usage-cli-'));
  try {
    const program=join(dir,'codex');
    await writeFile(program,`#!${process.execPath}
import {createInterface} from 'node:readline';
const lines=createInterface({input:process.stdin});let initialized=false;
lines.on('line',line=>{const m=JSON.parse(line);
if(m.method==='initialize')process.stdout.write(JSON.stringify({id:m.id,result:{}})+'\\n');
else if(m.method==='initialized')initialized=true;
else if(m.method==='account/rateLimits/read'&&initialized)process.stdout.write(JSON.stringify({id:m.id,result:{rateLimits:{primary:{usedPercent:7,windowDurationMins:300}}}})+'\\n');
else process.exit(2);
});`,{mode:0o700});
    assert.deepEqual(await readCodexUsage(program),[{label:'5h',usedPercent:7,resetsAt:null}]);
    await writeFile(program,`#!${process.execPath}\nprocess.exit(1);`,{mode:0o700});
    await assert.rejects(readCodexUsage(program));
  } finally {await rm(dir,{recursive:true,force:true});}
});

test('usage endpoint is authenticated and independent of state polling and persistence',async()=>{
  const dir=await mkdtemp(join(tmpdir(),'neura-usage-api-'));
  let complete!:(value:[])=>void;
  const pending=new Promise<[]>(resolve=>{complete=resolve;});
  const service=new ProviderUsageService({codex:()=>pending,claude:async()=>[]});
  const daemon=await createDaemon(dir,undefined,service);
  try {
    assert.equal((await daemon.app.inject('/v1/usage')).statusCode,401);
    const headers={authorization:`Bearer ${daemon.token}`};
    assert.equal((await daemon.app.inject({url:'/v1/usage',headers:{...headers,origin:'https://evil.invalid'}})).statusCode,401);
    const reading=daemon.app.inject({url:'/v1/usage',headers});
    const state=await daemon.app.inject({url:'/v1/state',headers});
    assert.equal(state.statusCode,200);assert.ok(state.json().features.includes('provider.usage'));
    complete([]);
    const response=await reading;
    assert.equal(response.headers['cache-control'],'no-store');
    assert.equal(response.json().providers[0].status,'unsupported');
    assert.equal(daemon.store.state().revision,state.json().revision);
  } finally {complete([]);await daemon.app.close();await rm(dir,{recursive:true,force:true});}
});
