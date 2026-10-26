import {appendFile, mkdir, stat, rename, rm} from 'node:fs/promises';
import {join} from 'node:path';
import {randomUUID} from 'node:crypto';
import type {Command} from './contracts.ts';

type Phase = 'operation.received'|'operation.executing'|'operation.success'|'operation.failure'|'daemon.start'|'daemon.end';
// Strict fields: no request payloads, error messages, paths or authentication data.
export class Diagnostics {
  private tail: Promise<void> = Promise.resolve();
  private queued = 0;
  private session = randomUUID();
  constructor(private directory: string, private limit = 1_048_576) {}
  record(event: Phase, operation?: Command['type'], operationId?: string, durationMs?: number) {
    if(this.queued >= 256) return;
    this.queued++;
    const row = JSON.stringify({time: new Date().toISOString(),session:this.session,event,operation,operationId,durationMs});
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
