import {channelCredential} from './channel-credentials.ts';
import {browserCredential} from './browser-credentials.ts';
import {claudeSessionInstructions} from './session-instructions.ts';
import {execFile} from 'node:child_process';
import {promisify} from 'node:util';
import {fileURLToPath} from 'node:url';
import {supportsActivity} from './agent-activity.ts';
import {Fault} from './contracts.ts';

export interface ClaudeMCPConnection {endpoint:()=>string;tokenPath:string}
const supported=new Map<string,Promise<boolean>>();
export function supportsClaudeMCP(program:string){
  let result=supported.get(program);
  if(!result){
    result=promisify(execFile)(program,['--help'],{timeout:3000,maxBuffer:256*1024})
      .then(({stdout})=>stdout.includes('--mcp-config')&&stdout.includes('--append-system-prompt')).catch(()=>false);
    supported.set(program,result);
  }
  return result;
}

export async function claudeMCPArguments(program:string,connection:ClaudeMCPConnection,workspaceId:string,terminalId:string){
  if(!await supportsClaudeMCP(program))throw new Fault('claude_mcp_unsupported','このClaude Code CLIはMCP自動接続に対応していません。Claude Codeを更新して再試行してください。',409);
  if(!await supportsActivity('claude',program))throw new Fault('claude_channels_unsupported','Claudeの双方向監督にはClaude Code 2.1.306以降とChannels対応環境が必要です。CLI更新と組織のChannels設定を確認してください。',409);
  const config={mcpServers:{neuraos:{type:'stdio',command:process.execPath,args:[fileURLToPath(new URL('./supervision-mcp.mjs',import.meta.url))],env:{
    NEURA_SUPERVISION_URL:connection.endpoint(),NEURA_SUPERVISION_TOKEN_FILE:connection.tokenPath,
    NEURA_CHANNEL_TOKEN:await channelCredential(connection.tokenPath,terminalId),NEURA_SUPERVISION_CHANNEL:'claude',NEURA_SUPERVISION_WORKSPACE:workspaceId,NEURA_SUPERVISION_TERMINAL:terminalId,
    NEURA_BROWSER_TOKEN:await browserCredential(connection.tokenPath,terminalId),
  }}}};
  // Inline configuration is scoped to this launch; leave user/project MCPs and hooks intact.
  return ['--dangerously-load-development-channels','server:neuraos','--mcp-config',JSON.stringify(config),'--append-system-prompt',
    claudeSessionInstructions];
}
