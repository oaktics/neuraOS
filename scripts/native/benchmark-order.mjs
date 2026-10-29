// Sequential ABBA comparison; no runtime/agent concurrency cap.
import {spawnSync} from 'node:child_process';
import {mkdirSync,writeFileSync} from 'node:fs';
import {resolve,join} from 'node:path';
const directory=resolve(process.env.NEURA_BENCH_EVIDENCE??`/tmp/neura-benchmark-${Date.now()}`);
mkdirSync(directory,{recursive:true,mode:0o700});
for(const [index,runtime]of ['native','legacy','legacy','native'].entries()){
 const path=join(directory,`${index+1}-${runtime}`);
 const env={...process.env,NEURA_BENCH_COUNTS:process.env.NEURA_BENCH_COUNTS??'1,5,10,20,32',NEURA_BENCH_EVIDENCE:path};
 if(runtime==='legacy')env.NEURA_BENCH_COMMAND=process.env.NEURA_BENCH_LEGACY_COMMAND??JSON.stringify(['node','--import','tsx','apps/daemon/src/main.ts']);
 else if(process.env.NEURA_BENCH_NATIVE_COMMAND)env.NEURA_BENCH_COMMAND=process.env.NEURA_BENCH_NATIVE_COMMAND;
 else delete env.NEURA_BENCH_COMMAND;
 const result=spawnSync(process.execPath,['scripts/native/benchmark-native-daemon.mjs',...(runtime==='legacy'?['--legacy']:[])],{env,encoding:'utf8',maxBuffer:32*1024*1024});
 writeFileSync(path+'.json',result.stdout??'',{mode:0o600});
 writeFileSync(path+'.stderr',result.stderr??'',{mode:0o600});
 if(result.status!==0)throw Error(`Benchmark ${index+1} ${runtime} failed; evidence at ${path}`);
}
console.log(JSON.stringify({directory,order:['native','legacy','legacy','native'],realBatteryMeasurement:false}));
