import { spawn } from 'node:child_process';
import { resolve } from 'node:path';
const env={...process.env,NEURA_DATA_DIR:resolve(process.env.NEURA_DATA_DIR??'.data')};
const runner=spawn(process.execPath,['--import','tsx','apps/runner/src/main.ts'],{stdio:'inherit',env});
const ui=spawn(process.execPath,['node_modules/vite/bin/vite.js','--config','apps/desktop/vite.config.ts'],{stdio:'inherit',env});
let stopping=false;const stop=()=>{if(stopping)return;stopping=true;runner.kill('SIGTERM');ui.kill('SIGTERM');};
for(const signal of ['SIGINT','SIGTERM'] as const)process.on(signal,stop);
runner.on('exit',stop);ui.on('exit',stop);
