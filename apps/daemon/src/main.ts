import {join} from 'node:path';
import {homedir} from 'node:os';
import {createDaemon} from './server.ts';
const dataDir=process.env.NEURA_DEV_DATA_DIR??join(homedir(),'Library/Application Support/neuraOS/Developer');
const {app}=await createDaemon(dataDir);
await app.listen({host:'127.0.0.1',port:Number(process.env.NEURA_DEV_PORT??4318)});
console.log('neuraOS Daemon ready (protocol v1, loopback only)');
for(const signal of ['SIGINT','SIGTERM'] as const)process.once(signal,()=>{void app.close().then(()=>process.exit(0));});
