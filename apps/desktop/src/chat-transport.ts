import {DefaultChatTransport,type ChatTransport,type UIMessage,type UIMessageChunk} from 'ai';
/** AI SDK subscription transport. Sending still uses the durable typed task command. */
export function chatTransport():ChatTransport<UIMessage>{
 const http=new DefaultChatTransport({api:'/api/chat'});
 return {resumeStreamIsReplay:true,sendMessages:async()=>{throw new Error('typed_chat_command_required');},reconnectToStream:async options=>{
  if(!('__TAURI_INTERNALS__' in window))return http.reconnectToStream(options);
  const {invoke,Channel}=await import('@tauri-apps/api/core');const subscriptionId=crypto.randomUUID();let ended=false;
  const unsubscribe=()=>{void invoke('runner_chat_unsubscribe',{subscriptionId}).catch(()=>{});};
  return new ReadableStream<UIMessageChunk>({start(controller){
   const channel=new Channel<UIMessageChunk>();channel.onmessage=chunk=>{if(!ended)controller.enqueue(chunk);};
   const abort=()=>{if(!ended){ended=true;controller.close();unsubscribe();}};options.abortSignal?.addEventListener('abort',abort,{once:true});
   void invoke('runner_chat_stream',{taskId:options.chatId,subscriptionId,onEvent:channel}).then(()=>{if(!ended){ended=true;controller.close();}},error=>{if(!ended){ended=true;controller.error(new Error(String(error)));}}).finally(()=>options.abortSignal?.removeEventListener('abort',abort));
   if(options.abortSignal?.aborted)abort();
  },cancel(){ended=true;unsubscribe();}});
 }};
}
export async function openExternal(url:string){if(!/^https?:\/\//i.test(url))return;if('__TAURI_INTERNALS__' in window){const {invoke}=await import('@tauri-apps/api/core');await invoke('open_external_url',{url});}else window.open(url,'_blank','noopener,noreferrer');}
