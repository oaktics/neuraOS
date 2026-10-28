// Observational hook: never print a decision, prompt, tool arguments, or output.
// The CLI waits only for this bounded local delivery, not for UI polling.
import {open} from 'node:fs/promises';
const observedAt=String(Date.now());
import {createConnection} from 'node:net';
const timer = setTimeout(() => process.exit(0), 800);
let input = '';
process.stdin.setEncoding('utf8');
process.stdin.on('data', chunk => {
  input += chunk;
  if (input.length > 1024 * 1024) process.exit(0);
});
process.stdin.on('error', () => process.exit(0));
process.stdin.on('end', async () => {
  try {
    const payload = JSON.parse(input), event = {observed_at:observedAt};
    for (const key of ['hook_event_name', 'session_id', 'transcript_path', 'agent_id', 'turn_id', 'tool_name', 'tool_use_id', 'source', 'notification_type']) {
      if (typeof payload[key] === 'string' && payload[key].length <= 4096) event[key] = payload[key];
    }
    if(typeof payload.last_assistant_message==='string'){
      event.last_assistant_message=payload.last_assistant_message.slice(-8000);
      // Correlate delayed Stop hooks with the assistant response they describe,
      // rather than allowing an old response to finish a newer dispatched turn.
      if(typeof payload.transcript_path==='string'){
        const file=await open(payload.transcript_path,'r').catch(()=>undefined);
        if(file)try{
          const size=(await file.stat()).size,buffer=Buffer.alloc(Math.min(size,256*1024));
          await file.read(buffer,0,buffer.length,size-buffer.length);
          for(const line of buffer.toString('utf8').split('\n').reverse())try{
            const row=JSON.parse(line);
            if(row.type==='assistant'&&row.sessionId===payload.session_id&&Array.isArray(row.message?.content)&&row.message.content.some(block=>block.type==='text'&&block.text===payload.last_assistant_message)){
              if(typeof row.timestamp==='string')event.assistant_timestamp=row.timestamp;break;
            }
          }catch{}
        }finally{await file.close();}
      }
    }
    while(event.last_assistant_message&&JSON.stringify(event).length>16000)event.last_assistant_message=event.last_assistant_message.slice(-Math.floor(event.last_assistant_message.length/2));
    const path = process.env.NEURA_ACTIVITY_SOCKET;
    if (!path) return process.exit(0);
    const socket = createConnection(path);
    socket.on('error', () => process.exit(0));
    socket.on('connect', () => socket.end(JSON.stringify(event) + '\n'));
    socket.on('close', () => {clearTimeout(timer); process.exit(0);});
  } catch {process.exit(0);}
});
