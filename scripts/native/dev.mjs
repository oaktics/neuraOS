import {execFileSync} from 'node:child_process';
import {resolve} from 'node:path';
const root=resolve(import.meta.dirname,'../..');
process.chdir(root);
execFileSync(process.execPath,['scripts/native/build.mjs'],{stdio:'inherit'});
// Re-register after building: an existing service may still point to the legacy Runtime.
execFileSync(process.execPath,['scripts/native/service.mjs','install'],{stdio:'inherit'});
execFileSync('open',[resolve('apps/macos/dist/neuraOS.app')]);
