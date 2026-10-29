import {readFile} from 'node:fs/promises';
import {join} from 'node:path';
export const uiPhaseIDs=['cef-init','page-ready','sheet-show','sheet-cancel','sheet-dismiss','app-modal','browser-resume','sidebar-tabs','diagnostic-export','exit'];
export function summarizePhases(text, timeoutMs=30000) {
 const phases=text.split('\n').flatMap(line=>{try {const e=JSON.parse(line);return uiPhaseIDs.includes(e.phase)&&['start','complete'].includes(e.state)&&Number.isFinite(e.elapsedMs)?[{phase:e.phase,state:e.state,elapsedMs:e.elapsedMs,...(Number.isInteger(e.index)?{index:e.index}:{}),...(Number.isFinite(e.deadlineMs)?{deadlineMs:e.deadlineMs}:{})}]:[];}catch{return [];}});
 return {timeoutMs,lastStarted:phases.findLast(p=>p.state==='start')??null,lastCompleted:phases.findLast(p=>p.state==='complete')??null,deadlines:phases.filter(p=>p.state==='start').map(({phase,index,deadlineMs,elapsedMs})=>({phase,index,deadlineMs,expectedByElapsedMs:deadlineMs==null?null:elapsedMs+deadlineMs}))};
}
export async function uiFailureSummary(directory,timeoutMs=30000) {
 let contents='';try{contents=await readFile(join(directory,'ui-phases.jsonl'),'utf8');}catch{}
 return {...summarizePhases(contents,timeoutMs),evidence:directory,phases:join(directory,'ui-phases.jsonl'),sample:join(directory,'ui-timeout.sample.txt'),diagnostic:join(directory,'diagnostic-report.json')};
}
