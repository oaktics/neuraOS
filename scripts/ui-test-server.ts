import { rm,mkdir,writeFile,chmod } from 'node:fs/promises';
import { resolve } from 'node:path';
import { spawn } from 'node:child_process';
const dir=resolve('.tmp/ui-tests');await rm(dir,{recursive:true,force:true});await mkdir(dir,{recursive:true});
const fakeCLI=resolve(dir,'fixture-cli.mjs');await writeFile(fakeCLI,`#!${process.execPath}
if(process.argv.includes('--version')){console.log('fixture-cli/1');process.exit(0);}
console.log('NATIVE CLI FIXTURE — permission input');process.stdin.on('data',data=>console.log('INPUT:'+data.toString().trim()));setInterval(()=>{},1000);
`);await chmod(fakeCLI,0o755);
const child=spawn(process.execPath,['--import','tsx','scripts/dev.ts'],{stdio:'inherit',env:{...process.env,NEURA_DATA_DIR:dir,NEURA_RUNNER_PORT:'4327',NEURA_ALLOW_FIXTURES:'1',NEURA_CODEX_PATH:fakeCLI,NEURA_CLAUDE_PATH:fakeCLI}});
for(const signal of ['SIGINT','SIGTERM'] as const)process.on(signal,()=>child.kill(signal));child.on('exit',code=>process.exit(code??0));
