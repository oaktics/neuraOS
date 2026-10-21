// npm's node-pty prebuilt archive may omit the helper executable bit on macOS.
import {createRequire} from 'node:module';import {dirname,join} from 'node:path';import {chmod,access} from 'node:fs/promises';
if(process.platform==='darwin'){const require=createRequire(import.meta.url),root=dirname(require.resolve('node-pty/package.json'));for(const dir of [`prebuilds/darwin-${process.arch}`,'build/Release']){const helper=join(root,dir,'spawn-helper');try{await access(helper);await chmod(helper,0o755);}catch(error){if(error.code!=='ENOENT')throw error;}}}
