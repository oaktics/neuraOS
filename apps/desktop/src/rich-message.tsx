import React,{memo,useState} from 'react';
import {Streamdown} from 'streamdown';
import {createCodePlugin} from '@streamdown/code';
import {mermaid} from '@streamdown/mermaid';
import {math} from '@streamdown/math';
import {cjk} from '@streamdown/cjk';
import {Copy,Check,Download,ArrowDown} from 'lucide-react';
import {StickToBottom,useStickToBottomContext} from 'use-stick-to-bottom';
import {openExternal} from './chat-transport.ts';
import 'streamdown/styles.css';
import 'katex/dist/katex.min.css';
import './rich-message.css';
const code=createCodePlugin({themes:['github-light','github-light']});
const translations={copyCode:'コードをコピー',copied:'コピーしました',copyTable:'表をコピー',copyTableAsCsv:'CSVでコピー',copyTableAsMarkdown:'Markdownでコピー',downloadFile:'ファイルを保存',downloadDiagram:'図を保存',downloadDiagramAsSvg:'SVGで保存',downloadDiagramAsPng:'PNGで保存',downloadTable:'表を保存',viewFullscreen:'拡大表示',exitFullscreen:'拡大表示を終了',zoomIn:'拡大',zoomOut:'縮小',resetView:'表示をリセット',errorMermaid:'図を表示できません',mermaidAriaLabel:'図',close:'閉じる'};
export const RichMessage=memo(function RichMessage({text,streaming=false}:{text:string;streaming?:boolean}){
 return <Streamdown className="rich-markdown" mode={streaming?'streaming':'static'} isAnimating={streaming} caret={streaming?'circle':undefined} animated={streaming?{animation:'fadeIn',duration:180}:false} plugins={{code,mermaid,math,cjk}} shikiTheme={['github-light','github-light']} mermaid={{config:{theme:'neutral',securityLevel:'strict',fontFamily:'-apple-system, sans-serif'}}} translations={translations} skipHtml components={{a:({href,children})=><a href={href} onClick={e=>{e.preventDefault();if(href)void openExternal(href);}} rel="noreferrer">{children}</a>,img:({src,alt})=><span className="markdown-image-link">{typeof src==='string'&&/^https?:\/\//.test(src)?<a href={src} onClick={e=>{e.preventDefault();void openExternal(src);}}>{alt||'画像を開く'} ↗</a>:alt||'画像'}</span>}}>{text}</Streamdown>;
});
export function MessageActions({text}:{text:string}){const [copied,setCopied]=useState(false);return <div className="message-actions"><button aria-label="返信をコピー" title={copied?'コピーしました':'返信をコピー'} onClick={()=>{void navigator.clipboard.writeText(text).then(()=>{setCopied(true);setTimeout(()=>setCopied(false),1500);});}}>{copied?<Check size={14}/>:<Copy size={14}/>}<span>{copied?'コピーしました':''}</span></button><button aria-label="返信をMarkdownで保存" title="Markdownで保存" onClick={()=>{const url=URL.createObjectURL(new Blob([text],{type:'text/markdown;charset=utf-8'}));const link=document.createElement('a');link.href=url;link.download='neuraOS-response.md';link.click();setTimeout(()=>URL.revokeObjectURL(url),1000);}}><Download size={14}/></button></div>;}
function ScrollToLatest(){const {isAtBottom,scrollToBottom}=useStickToBottomContext();return !isAtBottom?<button className="chat-scroll-latest" aria-label="最新のメッセージへ" onClick={()=>void scrollToBottom()}><ArrowDown size={15}/>最新へ</button>:null;}
export function ConversationView({children,label}:{children:React.ReactNode;label:string}){return <StickToBottom className="chat-history" initial="instant" resize="smooth" role="log" aria-label={label}><StickToBottom.Content className="chat-history-content">{children}</StickToBottom.Content><ScrollToLatest/></StickToBottom>;}
