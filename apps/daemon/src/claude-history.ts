import {open} from 'node:fs/promises';
import {Fault} from './contracts.ts';

// Byte cursors and bounded reads keep long Claude transcripts off the daemon's
// event loop. Tool calls/results remain visible, including their IDs and payload.
export async function claudeHistory(path:string|undefined,cursor?:string){
  if(!path)return {data:[],nextCursor:null};
  const file=await open(path,'r').catch(()=>undefined);
  if(!file)return {data:[],nextCursor:null};
  try{
    const size=(await file.stat()).size,end=cursor===undefined?size:Number(cursor);
    if(!Number.isSafeInteger(end)||end<0||end>size)throw new Fault('invalid_cursor','会話カーソルが不正です。');
    const start=Math.max(0,end-2*1024*1024),buffer=Buffer.alloc(end-start);
    await file.read(buffer,0,buffer.length,start);
    const first=start===0?0:buffer.indexOf(10)+1;
    const records:{offset:number;value:any}[]=[];
    let offset=first;
    while(offset<buffer.length){
      const newline=buffer.indexOf(10,offset),next=newline<0?buffer.length:newline;
      try{const value=JSON.parse(buffer.subarray(offset,next).toString('utf8'));if(value.uuid&&!value.isSidechain&&value.message)records.push({offset:start+offset,value});}catch{}
      offset=next+1;
    }
    const selected=records.slice(-20),next=records.length>20?selected[0].offset:start===0?0:start+first;
    const data=selected.reverse().map(({value:x})=>({id:x.uuid,status:'completed',items:(Array.isArray(x.message.content)?x.message.content:[{type:'text',text:String(x.message.content??'')}]).map((block:any,index:number)=>({id:`${x.uuid}:${index}`,type:block.type==='text'?(x.type==='user'?'userMessage':'agentMessage'):block.type,text:block.type==='text'?block.text:JSON.stringify(block)}))}));
    // A single oversized record cannot prevent pagination making progress.
    if(!data.length&&end>0)data.push({id:`transcript-window:${end}`,status:'completed',items:[{id:`transcript-window:${end}`,type:'historyNotice',text:'この範囲には表示可能な記録がありません（巨大な記録は省略）。元のtranscriptに実行証跡が保持されています。'}]});
    return {data,nextCursor:next>0&&next<end?String(next):start>0?String(start):null};
  }finally{await file.close();}
}
