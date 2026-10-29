// Join redacted request IDs to runtime intervals, including unfinished/timeouts.
import {readFile} from 'node:fs/promises';
import {join} from 'node:path';
import {pathToFileURL} from 'node:url';
export function correlate(outliers,events,pressure){
 return outliers.map(outlier=>{
  const intervals=events.filter(e=>e.requestId===outlier.requestId);
  const start=Date.parse(outlier.time),end=start+outlier.elapsedMs;
  const adjacent=pressure.filter(p=>Date.parse(p.time)>=start-1000&&Date.parse(p.time)<=end+1000);
  return {requestId:outlier.requestId,time:outlier.time,elapsedMs:outlier.elapsedMs,status:outlier.status,
   intervals,pressure:adjacent,httpComplete:intervals.some(e=>e.event==='http.received')&&intervals.some(e=>e.event==='http.response'),
   droppedEvents:events.reduce((n,e)=>n+(e.droppedEvents??0),0)};
 });
}
const lines=async path=>{try{return(await readFile(path,'utf8')).trim().split('\n').filter(Boolean).map(JSON.parse);}catch(e){if(e.code==='ENOENT')return [];throw e;}};
if(process.argv[1]&&import.meta.url===pathToFileURL(process.argv[1]).href){
 const dir=process.argv[2];if(!dir)throw Error('Pass one benchmark count evidence directory');
 const events=[...await lines(join(dir,'runtime','daemon.previous.jsonl')),...await lines(join(dir,'runtime','daemon.jsonl'))];
 console.log(JSON.stringify(correlate(await lines(join(dir,'http-outliers.jsonl')),events,await lines(join(dir,'pressure.jsonl'))),null,2));
}
