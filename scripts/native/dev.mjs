import {execFileSync} from 'node:child_process';
import {resolve} from 'node:path';
const root=resolve(import.meta.dirname,'../..');
process.chdir(root);
const command=[ '--import',resolve('node_modules/tsx/dist/loader.mjs'),resolve('scripts/native/service.ts') ];
try {execFileSync(process.execPath,[...command,'status'],{stdio:'ignore'});}
catch {execFileSync(process.execPath,[...command,'install'],{stdio:'inherit'});}
execFileSync(process.execPath,['scripts/native/build.mjs'],{stdio:'inherit'});
execFileSync('open',[resolve('apps/macos/dist/neuraOS.app')]);
