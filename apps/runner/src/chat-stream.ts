import type {FastifyInstance} from 'fastify';
import {createUIMessageStream,pipeUIMessageStreamToResponse} from 'ai';
import {Id} from '../../../packages/contracts/src/index.ts';
import {ensure} from '../../../packages/policy/src/index.ts';
import type {Hub} from './hub.ts';import type {Engine} from './engine.ts';
/** Subscription only: disconnecting the desktop never cancels the authorized Run. */
export function registerChatStreams(app:FastifyInstance,hub:Hub,engine:Engine){
 app.get('/api/chat/:taskId/stream',async(req,res)=>{
  const taskId=Id.parse((req.params as {taskId:string}).taskId),task=hub.read().tasks.find(t=>t.id===taskId);ensure(task&&['vice_president','director_chat'].includes(task.work?.role??''),'chat_not_found');
  let closed=false;res.raw.on('close',()=>{closed=true;});
  const stream=createUIMessageStream({execute:async({writer})=>{
   writer.write({type:'start',messageId:`reply-${taskId}`});writer.write({type:'text-start',id:taskId});let sent='';
   while(!closed){
    const current=hub.read().tasks.find(t=>t.id===taskId);const answer=hub.read().conversations?.flatMap(c=>c.messages).find(m=>m.taskId===taskId&&m.role==='assistant');const text=answer?.content??engine.chatDrafts.get(taskId)??'';
    if(text.startsWith(sent)&&text.length>sent.length){writer.write({type:'text-delta',id:taskId,delta:text.slice(sent.length)});sent=text;}
    if(answer){writer.write({type:'text-end',id:taskId});writer.write({type:'finish',finishReason:'stop'});break;}
    if(!current||!['queued','running','verifying'].includes(current.status)){writer.write({type:'text-end',id:taskId});writer.write({type:'finish',finishReason:'stop'});break;}
    await new Promise(r=>setTimeout(r,75));
   }
  },onError:()=> '応答の受信が途切れました。保存された会話は引き続き確認できます。'});
  res.hijack();pipeUIMessageStreamToResponse({response:res.raw,stream,headers:{'Cache-Control':'no-store'},keepAliveMs:10000});
 });
}
