import {Workspace} from './workspace.tsx';
import React,{useEffect,useRef,useState} from 'react';
import {ArrowUp,ArrowRight,MessageSquare,Plus,Square,Users,ChevronRight} from 'lucide-react';
import {Button,Select,SelectOption,TextArea} from '../../../packages/ui/src/controls.tsx';
import type {State,Command,Task,Project} from '../../../packages/contracts/src/index.ts';
import {ConversationView,RichMessage,MessageActions} from './rich-message.tsx';
import {StreamingReply} from './chat-streaming.tsx';
import {labels,errorText} from './api.ts';
type Mutate=(command:Command)=>Promise<boolean>;
export function PresidentChat({state,project,allowFixtures,mutate,onTask,onProjects,initialText}:{initialText?:string;state:State;project?:Project;allowFixtures:boolean;mutate:Mutate;onTask:(id:string)=>void;onProjects:()=>void}){
  const existing=state.conversations?.find(c=>c.projectId===(project?.id??null));
  const [id]=useState(()=>existing?.id??crypto.randomUUID()),[provider,setProvider]=useState(existing?.provider??'codex'),[text,setText]=useState(initialText??''),[sending,setSending]=useState(false);
  const composing=useRef(false),compositionEndedAt=useRef(-Infinity);
  const conversation=state.conversations?.find(c=>c.id===(existing?.id??id)),messages=conversation?.messages??[];
  const pending=state.tasks.find(t=>t.work?.conversationId===conversation?.id&&['vice_president','director_chat'].includes(t.work?.role??'')&&['queued','running','verifying'].includes(t.status));
  const send=async()=>{if(composing.current||!text.trim()||pending||sending)return;setSending(true);try{const ok=await mutate({type:'chat.send',id:crypto.randomUUID(),conversationId:conversation?.id??id,projectId:project?.id??null,provider:project?.provider??provider,content:text.trim()});if(ok)setText('');}finally{setSending(false);}};
  return <div className={`president-chat ${project?'project-chat':''}`}>
    {!project&&<header className="chat-page-heading"><div><div className="eyebrow">YOUR OFFICE</div><h1>副社長</h1><p>考えごとも、仕事の依頼も。まずはここから。</p></div><div className="chat-provider"><Select aria-label="副社長のAI" value={provider} disabled={!!pending} onValueChange={value=>setProvider(value as typeof provider)}><SelectOption value="codex">Codex · ローカル</SelectOption><SelectOption value="claude">Claude Code · ローカル</SelectOption>{allowFixtures&&<SelectOption value="fixture">固定fixture（試験専用）</SelectOption>}</Select></div></header>}
    <ConversationView label={project?'部長との会話':'副社長との会話'}>
      {!messages.length&&<div className="chat-welcome"><MessageSquare size={26} strokeWidth={1.4}/><h2>{project?'このプロジェクト、何から進めますか。':'今日は、何を一緒に考えましょう。'}</h2><p>{project?'目的と進め方を部長に相談できます。依頼すると社員が分担して作業します。':'まだ曖昧な相談でも大丈夫です。目的を整理し、担当するプロジェクトを一緒に決めます。'}</p>{!project&&!state.projects.length&&<Button className="secondary" onClick={onProjects}><Plus size={14}/>プロジェクトを用意する</Button>}</div>}
      {messages.map(message=>{const task=state.tasks.find(t=>t.id===message.taskId);const answered=messages.some(m=>m.role==='assistant'&&m.taskId===message.taskId);return <article key={message.id} className={`chat-message ${message.role}`}><div className="chat-author">{message.role==='assistant'&&<span className="assistant-avatar">n°</span>}{message.role==='user'?'あなた · 社長':project?'部長':'副社長'}<time>{new Date(message.createdAt).toLocaleTimeString('ja-JP',{hour:'2-digit',minute:'2-digit'})}</time></div>{message.role==='assistant'?<><RichMessage text={message.content}/><MessageActions text={message.content}/></>:<div className="chat-message-text">{message.content}</div>}
        {message.proposals.map((proposal,index)=><div className="delegation-proposal" key={index}><small>{state.projects.find(p=>p.id===proposal.projectId)?.name} / 部長への依頼</small><strong>{proposal.title}</strong><p>{proposal.deliverable}</p>{proposal.taskId?<Button className="secondary" onClick={()=>onTask(proposal.taskId!)}>仕事の進捗を見る<ArrowRight size={14}/></Button>:<Button className="primary" onClick={()=>void mutate({type:'chat.delegate',conversationId:conversation!.id,messageId:message.id,proposalIndex:index,id:crypto.randomUUID()})}>部長に依頼<ArrowRight size={14}/></Button>}</div>)}
        {message.role==='user'&&!answered&&task&&['failed','blocked','canceled'].includes(task.status)&&<div className="chat-response-error"><span>{task.status==='canceled'?'応答を停止しました。':`応答を取得できませんでした。${errorText(new Error(task.reason))}`}</span><button className="text-button" onClick={()=>onTask(task.id)}>実行詳細を確認</button></div>}
      </article>;})}
      {pending&&!messages.some(m=>m.taskId===pending.id&&m.role==='assistant')&&<StreamingReply key={pending.id} taskId={pending.id} label={project?'部長':'副社長'}/>}
    </ConversationView>
    <form className="chat-composer" onSubmit={event=>{event.preventDefault();void send();}}><TextArea aria-label={project?'部長へのメッセージ':'副社長へのメッセージ'} placeholder={project?'部長に相談する、仕事を依頼する…':'副社長に相談する、やりたいことを伝える…'} value={text} onChange={event=>setText(event.target.value)} rows={3} onCompositionStart={()=>{composing.current=true;}} onCompositionEnd={()=>{composing.current=false;compositionEndedAt.current=performance.now();}} onKeyDown={event=>{
      if(event.key!=='Enter'||event.shiftKey)return;
      // WebKit can report compositionend before the confirmation Enter keydown.
      // keyCode 229 also covers IMEs whose isComposing flag is already false.
      if(composing.current||event.nativeEvent.isComposing||event.nativeEvent.keyCode===229)return;
      event.preventDefault();
      if(performance.now()-compositionEndedAt.current<50)return;
      void send();
    }}/><div className="chat-compose-bottom"><small>{project?`${project.provider==='claude'?'Claude Code':'Codex'} · 部長と社員の共通AI`:'Enter で送信 · Shift + Enter で改行'}</small>{pending?<Button className="secondary" type="button" aria-label="応答を停止" onClick={()=>void mutate({type:'task.control',taskId:pending.id,expectedVersion:pending.version,action:'cancel'})}><Square size={13}/>停止</Button>:<Button className="primary" type="submit" disabled={sending||!text.trim()} aria-label="メッセージを送信"><ArrowUp size={17}/></Button>}</div></form>
  </div>;
}
export function ProjectOffice({project,state,allowFixtures,mutate,onTask,onCreate}:{project:Project;state:State;allowFixtures:boolean;mutate:Mutate;onTask:(id:string)=>void;onCreate:()=>void}){
  const [tab,setTab]=useState<'chat'|'work'|'workspace'>('chat'),[context,setContext]=useState('');const tasks=state.tasks.filter(t=>t.projectId===project.id&&!['director_chat','vice_president'].includes(t.work?.role??'')&&!t.work?.parentId);
  return <div className="project-office"><header className="project-office-heading"><h1 title={project.description}>{project.name}</h1><div className="tabs"><button className={tab==='chat'?'active':''} onClick={()=>setTab('chat')}><MessageSquare size={14}/>部長との相談</button><button className={tab==='work'?'active':''} onClick={()=>setTab('work')}><Users size={14}/>仕事<span>{tasks.length}</span></button><button className={tab==='workspace'?'active':''} onClick={()=>setTab('workspace')}>ワークスペース</button><button className="project-new-task" onClick={onCreate}><Plus size={14}/>新しいタスク</button></div><div className="project-provider-setting"><label><span className="sr-only">このプロジェクトのAI</span><Select aria-label="このプロジェクトのAI" value={project.provider??'codex'} onValueChange={provider=>void mutate({type:'project.save',...project,provider:provider as 'codex'|'claude'|'fixture'})}><SelectOption value="codex">Codex · ローカル</SelectOption><SelectOption value="claude">Claude Code · ローカル</SelectOption>{allowFixtures&&<SelectOption value="fixture">固定fixture（試験専用）</SelectOption>}</Select></label><label><Users size={14} aria-hidden="true"/><Select aria-label="社員数" value={String(project.maxWorkers??3)} onValueChange={value=>void mutate({type:'project.save',...project,maxWorkers:Number(value)})}><SelectOption value="2">2人</SelectOption><SelectOption value="3">3人</SelectOption><SelectOption value="4">4人</SelectOption></Select></label></div></header>

    {tab==='workspace'?<Workspace key={project.id} project={project} state={state} onContext={text=>{setContext(text);setTab('chat');}}/>:tab==='chat'?<PresidentChat initialText={context} key={project.id+context} state={state} project={project} allowFixtures={allowFixtures} mutate={mutate} onTask={onTask} onProjects={()=>{}}/>:<div className="project-work-list">{tasks.map(t=><button key={t.id} className="project-work-row" onClick={()=>onTask(t.id)}><span><strong>{t.title}</strong><small>{t.work?.role==='director'?'部長が取りまとめ':t.work?.role==='employee'?'社員の担当':'タスク'}</small></span><span>{labels[t.status]}</span><ChevronRight size={15}/></button>)}{!tasks.length&&<p className="muted">部長へ依頼した仕事と、作成したタスクがここに並びます。</p>}</div>}
  </div>;
}
export function TeamProgress({task,state,onTask}:{task:Task;state:State;onTask:(id:string)=>void}){
  const children=state.tasks.filter(t=>t.work?.parentId===task.id);if(!children.length)return null;
  return <section className="team-progress"><div className="section-heading"><h2><Users size={16}/>社員の仕事</h2><small>{children.filter(t=>t.status==='succeeded').length} / {children.length} 完了</small></div>{children.map(t=><button className="project-work-row" key={t.id} onClick={()=>onTask(t.id)}><span><strong>{t.title}</strong><small>{t.provider==='claude'?'Claude Code':'Codex'} · {t.artifacts.length}件の成果物</small></span><span className={`badge ${t.status}`}>{labels[t.status]}</span><ChevronRight size={15}/></button>)}</section>;
}
