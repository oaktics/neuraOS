import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { mkdir,writeFile,mkdtemp,rm } from 'node:fs/promises';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { CodexAdapter,CodexRpc } from '../packages/adapters/codex/index.ts';
import { ClaudeAdapter } from '../packages/adapters/claude/index.ts';
import { spawnIsolated } from '../packages/execution/src/sandbox.ts';
const exec=promisify(execFile);const results:Record<string,unknown>={at:new Date().toISOString(),platform:process.platform,node:process.version,checks:{}};const checks=results.checks as Record<string,unknown>;
for(const [name,command,args] of [['docker','docker',['version','--format','{{.Server.Version}}']],['codex',process.env.NEURA_CODEX_PATH??'/opt/homebrew/bin/codex',['--version']],['claude','claude',['--version']]] as [string,string,string[]][]){try{checks[name]={ok:true,version:(await exec(command,args,{timeout:10000})).stdout.trim()};}catch{checks[name]={ok:false};}}
results.providers=await Promise.all([new CodexAdapter().probeCapabilities(),new ClaudeAdapter().probeCapabilities()]);
if(process.platform==='darwin'){
  const dir=await mkdtemp(join(tmpdir(),'neura-codex-probe-'));let rpc:CodexRpc|undefined;
  try{
    await mkdir(join(dir,'.codex'),{recursive:true});
    const child=await spawnIsolated(process.env.NEURA_CODEX_PATH??'/opt/homebrew/bin/codex',['app-server','--strict-config','--listen','stdio://','-c','features.shell_tool=false','-c','features.apps=false','-c','features.plugins=false','-c','features.shell_snapshot=false','-c','features.memories=false'],dir,32123,{PATH:'/usr/bin:/bin:/opt/homebrew/bin',HOME:dir,CODEX_HOME:join(dir,'.codex'),TMPDIR:dir});
    rpc=new CodexRpc(child);const result=await rpc.request('initialize',{clientInfo:{name:'neuraos-probe',title:'neuraOS capability probe',version:'0.1.0'}});rpc.notify('initialized');checks.codexHandshake={ok:true,userAgent:result.userAgent??null,inferenceCalled:false};
  }catch(e){checks.codexHandshake={ok:false,reason:e instanceof Error?e.message:'unknown',inferenceCalled:false};}finally{rpc?.close();await rm(dir,{recursive:true,force:true});}
  checks.claudeInference={tested:false,note:'実推論は NEURA_PROBE_PROVIDER=claude pnpm exec tsx scripts/probe-local.ts で別途確認する。'};
}
await mkdir('.tmp/evidence',{recursive:true});await writeFile('.tmp/evidence/doctor.json',JSON.stringify(results,null,2));console.log(JSON.stringify(results,null,2));
