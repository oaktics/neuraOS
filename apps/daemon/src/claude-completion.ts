import {open,stat} from 'node:fs/promises';
import type {ActivityEvent} from './agent-activity.ts';

// A missing hook is not evidence of completion. Only Claude's persisted end-of-
// turn marker can repair it; silence, process age and assistant text cannot.
export async function claudeCompletion(path:string,sessionId:string,after:number):Promise<ActivityEvent|undefined>{
  const file=await open(path,'r').catch(()=>undefined);
  if(!file)return;
  try{
    const before=await file.stat(),size=before.size,start=Math.max(0,size-512*1024),buffer=Buffer.alloc(size-start);
    const {bytesRead}=await file.read(buffer,0,buffer.length,start);
    if(bytesRead!==buffer.length)return;
    const text=buffer.toString('utf8'),lines=text.split('\n');
    if(start)lines.shift();
    // An unfinished write may be the start of the next turn. Wait for its flush.
    if(lines.pop()!=='')return;
    let completed:ActivityEvent|undefined,summary:string|undefined;
    for(const line of lines){
      let row;try{row=JSON.parse(line);}catch{return;}
      if(row.isSidechain||row.sessionId!==sessionId)continue;
      const timestamp=Date.parse(row.timestamp??'');
      if(!Number.isFinite(timestamp))continue;
      if(['user','assistant','api-request'].includes(row.type))completed=undefined;
      if(row.type==='assistant'){
        summary=Array.isArray(row.message?.content)?row.message.content.filter((b:any)=>b.type==='text').map((b:any)=>b.text).join('\n').slice(-8000):undefined;
      }
      if(row.type==='system'&&row.subtype==='turn_duration'&&timestamp>=after){
        completed={hook_event_name:'Stop',session_id:sessionId,transcript_path:path,observed_at:String(timestamp),...(summary?{last_assistant_message:summary}:{})};
      }
    }
    if(!completed)return;
    const afterStat=await stat(path).catch(()=>undefined);
    // A newer prompt may be appended while its hook is delayed or lost. Never
    // publish a completion from a stale prefix or a replaced/truncated file.
    if(!afterStat||before.dev!==afterStat.dev||before.ino!==afterStat.ino||before.size!==afterStat.size||before.mtimeMs!==afterStat.mtimeMs||before.ctimeMs!==afterStat.ctimeMs)return;
    return completed;
  }finally{await file.close();}
}
