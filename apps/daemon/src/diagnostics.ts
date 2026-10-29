import {appendFile, mkdir, stat, rename, rm} from 'node:fs/promises';
import {join} from 'node:path';
import {randomUUID} from 'node:crypto';
import {monitorEventLoopDelay,performance} from 'node:perf_hooks';
import type {Command} from './contracts.ts';

type Phase = 'operation.received'|'operation.executing'|'operation.success'|'operation.failure'|'daemon.start'|'daemon.end';
// Strict fields: no request payloads, error messages, paths or authentication data.
export class Diagnostics {
  private tail: Promise<void> = Promise.resolve();
  private queued = 0;
  private session = randomUUID();
  constructor(private directory: string, private limit = 1_048_576) {}
  startPerformanceMonitoring(intervalMs=10000){
    const delay=monitorEventLoopDelay({resolution:20});delay.enable();
    let previous=performance.eventLoopUtilization();
    const timer=setInterval(()=>{
      const utilization=performance.eventLoopUtilization(previous);previous=performance.eventLoopUtilization();
      const memory=process.memoryUsage();
      this.enqueue(JSON.stringify({time:new Date().toISOString(),session:this.session,event:'daemon.performance',
        eventLoopP99Ms:delay.percentile(99)/1e6,eventLoopMaxMs:delay.max/1e6,
        eventLoopUtilization:utilization.utilization,rssBytes:memory.rss,heapUsedBytes:memory.heapUsed}));
      delay.reset();
    },intervalMs);timer.unref();
    return ()=>{clearInterval(timer);delay.disable();};
  }
  record(event: Phase, operation?: Command['type'], operationId?: string, durationMs?: number) {
    this.enqueue(JSON.stringify({time: new Date().toISOString(),session:this.session,event,operation,operationId,durationMs}));
  }
  private enqueue(row:string){
    if(this.queued >= 256) return;
    this.queued++;
    this.tail = this.tail.then(async()=>{
      await mkdir(this.directory,{recursive:true,mode:0o700});
      const file=join(this.directory,'daemon.jsonl');
      if(await stat(file).then(s=>s.size,()=>0)>=this.limit){
        await rm(join(this.directory,'daemon.previous.jsonl'),{force:true});
        await rename(file,join(this.directory,'daemon.previous.jsonl'));
      }
      await appendFile(file,row+'\n',{mode:0o600});
    }).catch(()=>{}).finally(()=>{this.queued--;});
  }
  async flush(){await this.tail;}
}
