import React,{useEffect,useMemo} from 'react';
import {useChat} from '@ai-sdk/react';
import {chatTransport} from './chat-transport.ts';
import {RichMessage} from './rich-message.tsx';
export function StreamingReply({taskId,label}:{taskId:string;label:string}){
 const transport=useMemo(()=>chatTransport(),[]);const {messages,resumeStream,stop,error}=useChat({id:taskId,transport,experimental_throttle:50});
 useEffect(()=>{void resumeStream();return()=>{void stop();};},[taskId,resumeStream,stop]);
 const text=messages.filter(m=>m.role==='assistant').flatMap(m=>m.parts).filter(p=>p.type==='text').map(p=>p.text).join('');
 return <article className="chat-message assistant streaming" aria-label="生成中の応答"><div className="chat-author"><span className="assistant-avatar">n°</span>{label}<span className="streaming-label">応答中</span></div>{text?<RichMessage text={text} streaming/>:<div className="chat-thinking"><span/>{label}が考えています</div>}{error&&<small className="muted">受信が途切れました。保存後に回答を表示します。</small>}</article>;
}
