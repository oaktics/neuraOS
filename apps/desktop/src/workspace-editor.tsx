import React,{useRef} from 'react';import Editor,{loader} from '@monaco-editor/react';
import * as monaco from 'monaco-editor/editor/editor.api';
import EditorWorker from 'monaco-editor/editor/editor.worker?worker';
import 'monaco-editor/languages/definitions/typescript/register';
import 'monaco-editor/languages/definitions/javascript/register';
import 'monaco-editor/languages/definitions/markdown/register';
import 'monaco-editor/languages/definitions/python/register';
import 'monaco-editor/languages/definitions/shell/register';
(self as unknown as {MonacoEnvironment:unknown}).MonacoEnvironment={getWorker:()=>new EditorWorker()};loader.config({monaco});
export default function WorkspaceEditor({path,value,onChange,onSave}:{path:string;value:string;onChange:(value:string)=>void;onSave:()=>void}){const save=useRef(onSave);save.current=onSave;return <Editor path={path} value={value} theme="vs" onChange={value=>onChange(value??'')} onMount={editor=>editor.addCommand(monaco.KeyMod.CtrlCmd|monaco.KeyCode.KeyS,()=>save.current())} options={{editContext:false,fontSize:13,fontFamily:'SFMono-Regular, Menlo, monospace',minimap:{enabled:false},padding:{top:14},scrollBeyondLastLine:false,automaticLayout:true,tabSize:2,renderLineHighlight:'gutter'}}/>;}
