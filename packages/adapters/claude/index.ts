import {execFile} from 'node:child_process';
import {promisify} from 'node:util';
import {mkdir,realpath} from 'node:fs/promises';
import {join} from 'node:path';
import {createInterface} from 'node:readline';
import {AgentOutput,AgentOutputJsonSchema} from '../../contracts/src/index.ts';
import type {AgentAdapter,AdapterContext,Capabilities,AdapterResult} from '../index.ts';
import {chatTextEmitter} from '../chat-stream.ts';
import {buildPrompt} from '../index.ts';
import {DomainError,ensure} from '../../policy/src/index.ts';
import {inferenceProxy} from '../proxy.ts';
import {spawnIsolated,stopProcessGroup} from '../../execution/src/sandbox.ts';
import {providerAuth,cliPath} from '../local-auth.ts';
const exec=promisify(execFile);
/** The user's installed Claude Code CLI; auth remains in the parent inference broker. */
export class ClaudeAdapter implements AgentAdapter{
  async probeCapabilities():Promise<Capabilities>{const executable=await cliPath('claude');let version='unavailable';if(executable)try{version=(await exec(executable,['--version'],{timeout:5000})).stdout.trim();}catch{}
    return {provider:'claude',available:version!=='unavailable',resume:true,interrupt:true,structuredOutput:true,usage:true,approvals:false,isolation:process.platform==='darwin',version,reason:!executable?'Claude Code CLIが見つかりません':!(await providerAuth('claude'))?'端末で claude auth login を実行してください':''};}
  async execute(c:AdapterContext):Promise<AdapterResult>{
    const executable=await cliPath('claude');ensure(executable,'claude_cli_missing');const auth=await providerAuth('claude');ensure(auth,'claude_auth_missing');ensure(c.task.budget.maxUsd===null||auth.kind==='api','cost_cap_unsupported');
    const proxy=await inferenceProxy('claude',auth.token,c.allowance?.calls??Math.max(1,c.task.budget.maxCalls-(c.task.runs.at(-1)?.calls??1)+1),auth,c.allowance?{tokens:c.allowance.tokens}:undefined);
    await mkdir(c.runtimeDir,{recursive:true,mode:0o700});const root=await realpath(c.runtimeDir),home=join(root,'home');await mkdir(home,{recursive:true,mode:0o700});
    const {$schema:_schema,...cliSchema}=AgentOutputJsonSchema;
    const args=['--print','--output-format','stream-json','--include-partial-messages','--verbose','--tools','','--strict-mcp-config','--mcp-config','{"mcpServers":{}}','--setting-sources','','--permission-mode','dontAsk','--permission-prompts','none','--disable-slash-commands','--json-schema',JSON.stringify(cliSchema),...(auth.kind==='api'?['--bare']:['--safe-mode','--restricted'])];
    if(process.env.NEURA_CLI_DEBUG==='1')args.push('--debug-file',join(root,'cli-debug.log'));
    if(c.task.budget.maxUsd!==null)args.push('--max-budget-usd',String(Math.max(0.001,c.task.budget.maxUsd-(c.task.runs.at(-1)?.costUsd??0))));
    if(c.task.model)args.push('--model',c.task.model);const prior=c.freshSession?undefined:c.task.runs.at(-1)?.sessionId;if(prior)args.push('--resume',prior);
    const child=await spawnIsolated(executable,args,root,proxy.port,{PATH:'/usr/bin:/bin',HOME:home,TMPDIR:home,CLAUDE_CODE_TMPDIR:home,CLAUDE_CONFIG_DIR:join(home,'.claude'),ANTHROPIC_BASE_URL:proxy.url,...(auth.kind==='api'?{ANTHROPIC_API_KEY:'neura-gateway'}:{CLAUDE_CODE_OAUTH_TOKEN:'neura-gateway'}),CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC:'1',DISABLE_AUTOUPDATER:'1',LANG:'en_US.UTF-8'});
    const abort=()=>stopProcessGroup(child);c.signal.addEventListener('abort',abort,{once:true});if(c.signal.aborted)abort();
    try{return await new Promise<AdapterResult>((resolve,reject)=>{
      let chain=Promise.resolve();const streamed=chatTextEmitter(c);let partial='';let result:AdapterResult|undefined;let invalid=false;
      const lines=createInterface({input:child.stdout});child.stderr.resume();child.on('error',reject);
      lines.on('line',line=>{if(line.length>4*1024*1024){invalid=true;abort();return;}try{const message=JSON.parse(line);
        if(message.type==='stream_event'){const event=message.event;if(event?.type==='content_block_start')partial='';if(event?.type==='content_block_delta'){const delta=event.delta?.partial_json??(event.delta?.type==='text_delta'?event.delta.text:undefined);if(typeof delta==='string'){partial+=delta;streamed.push(partial);}}}
        if(message.type==='system'&&message.subtype==='init')chain=chain.then(()=>c.onSession(message.session_id,message.model??c.task.model,'claude-code-cli'));
        if(message.type==='result'){if(message.subtype!=='success'||message.is_error){invalid=true;return;}result={output:AgentOutput.parse(message.structured_output??JSON.parse(message.result)),tokens:(message.usage?.input_tokens??0)+(message.usage?.output_tokens??0)+(message.usage?.cache_creation_input_tokens??0)+(message.usage?.cache_read_input_tokens??0),costUsd:auth.kind==='api'?(message.total_cost_usd??null):null,calls:proxy.calls};}
      }catch{invalid=true;}});
      child.on('close',code=>{chain.then(()=>streamed.flush()).then(()=>{if(code===0&&result&&!invalid)resolve(result);else reject(new Error(c.signal.aborted?'interrupted':'claude_turn_failed'));},reject);});
      child.stdin.end(buildPrompt(c));
    });}catch(error){if(proxy.budgetExceeded)throw Object.assign(new DomainError('token_budget'),{usage:proxy.measured?{tokens:proxy.tokens,calls:proxy.calls,costUsd:null}:undefined});throw error;}finally{c.signal.removeEventListener('abort',abort);stopProcessGroup(child);await proxy.close();}
  }
}
