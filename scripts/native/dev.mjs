import {execFileSync} from 'node:child_process';
import {resolve} from 'node:path';
const root=resolve(import.meta.dirname,'../..');
process.chdir(root);
execFileSync(process.execPath,['scripts/native/build.mjs'],{stdio:'inherit'});
// Preserve running services (including legacy Node); install only when stopped/missing.
execFileSync(process.execPath,['scripts/native/service.mjs','ensure'],{stdio:'inherit'});
execFileSync('open',[resolve('apps/macos/dist/neuraOS.app')]);
