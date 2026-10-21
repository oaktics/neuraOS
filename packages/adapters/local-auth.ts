import {readFile,realpath,access} from 'node:fs/promises';
import {homedir} from 'node:os';
import {join,isAbsolute} from 'node:path';
import {execFile} from 'node:child_process';
import {promisify} from 'node:util';
import {readSecret} from '../connectors/src/secrets.ts';
const exec=promisify(execFile);
export type ProviderAuth={token:string;kind:'api'|'chatgpt'|'claude-login';accountId?:string};
/** Read only the selected CLI's credential. Never return it through IPC or logs. */
export async function providerAuth(provider:'codex'|'claude'):Promise<ProviderAuth|null>{
  if(provider==='codex'){
    try{const data=JSON.parse(await readFile(join(process.env.CODEX_HOME??join(homedir(),'.codex'),'auth.json'),'utf8'));if(data.tokens?.access_token)return {token:data.tokens.access_token,kind:'chatgpt',accountId:data.tokens.account_id};if(data.OPENAI_API_KEY)return {token:data.OPENAI_API_KEY,kind:'api'};}catch{}
  }else if(process.platform==='darwin'){
    try{const {stdout}=await exec('/usr/bin/security',['find-generic-password','-s','Claude Code-credentials','-w'],{timeout:5000,maxBuffer:65536});const data=JSON.parse(stdout);const oauth=data.claudeAiOauth;if(oauth?.accessToken&&(!oauth.expiresAt||oauth.expiresAt>Date.now()))return {token:oauth.accessToken,kind:'claude-login'};}catch{}
  }
  const key=await readSecret(provider==='codex'?'openai-api-key':'anthropic-api-key');return key?{token:key,kind:'api'}:null;
}
export async function cliPath(provider:'codex'|'claude'){
  const configured=provider==='codex'?process.env.NEURA_CODEX_PATH:process.env.NEURA_CLAUDE_PATH;
  const paths=configured?[configured]:provider==='codex'?['/opt/homebrew/bin/codex','/usr/local/bin/codex']: [join(homedir(),'.local/bin/claude'),'/opt/homebrew/bin/claude','/usr/local/bin/claude'];
  for(const path of paths){if(!isAbsolute(path))continue;try{await access(path);return await realpath(path);}catch{}}
  return null;
}
