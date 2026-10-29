// Development wrapper only. The installed app invokes the native helper directly.
import {execFileSync} from 'node:child_process';
import {resolve} from 'node:path';
const root=resolve(import.meta.dirname,'../..');
if(process.platform!=='darwin')throw Error('LaunchAgent is macOS-only');
const helper=resolve(root,'apps/macos/.build/release/NeuraUpdater');
const daemon=resolve(root,'crates/native-core/target/release/neura-native-core');
execFileSync(helper,['service',process.argv[2]??'status',daemon],{stdio:'inherit'});
