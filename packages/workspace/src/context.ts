export interface ContextOptions {query?:string;paths?:string[];maxBytes:number;maxFiles:number;manifestBytes?:number}
/** Selection is relevance only; WorkspaceManager still enforces path/secret boundaries. */
export function rankPaths(paths:string[],options:ContextOptions){
 const query=(options.query??'').toLowerCase(),wanted=new Set(options.paths??[]),terms=query.match(/[a-z][a-z0-9_-]{2,}/g)??[];
 const groups:[RegExp,RegExp][]=[[/画面|フロント|チャット|表示|ui|frontend/,/desktop|ui\/|\.tsx$|\.css$/],[/テスト|検証|証拠|受け入れ|test|検証記録/,/tests?\/|acceptance|playwright|verify/],[/バックエンド|実行制御|クラウド|runner|モデル連携/,/runner|cloud-api|adapters|task-domain|sync|contracts/],[/仕様|資料|文書|readme/,/docs\/|readme/i]];
 const score=(path:string)=>{const name=path.toLowerCase();return (wanted.has(path)?10000:0)+(query.includes(name)?500:0)+groups.reduce((n,[q,p])=>n+(q.test(query)&&p.test(name)?30:0),0)+terms.reduce((n,t)=>n+(name.includes(t)?5:0),0)+(/(^|\/)(readme\.md|package\.json)$/i.test(path)?8:0);};
 return [...paths].sort((a,b)=>score(b)-score(a)||a.localeCompare(b));
}
export function boundedText(text:string,maxBytes:number){const bytes=Buffer.from(text);if(bytes.length<=maxBytes)return text;return new TextDecoder('utf-8',{fatal:false}).decode(bytes.subarray(0,Math.max(0,maxBytes-60))).replace(/\uFFFD$/,'')+'\n[省略: この資料の全体は未提示]';}
export function contextOptions(task:{title:string;objective:string;work?:{phase:string;sourcePaths?:string[]}},tokens:number):ContextOptions{
 const planning=task.work?.phase==='planning';return {query:planning?'README package.json':task.title+' '+task.objective,paths:task.work?.sourcePaths,maxBytes:Math.min(planning?6000:18000,Math.max(0,Math.floor(tokens*.6))),maxFiles:planning?3:10,manifestBytes:planning?12000:2000};
}

export function reviewContext(children:import('../../contracts/src/index.ts').Task[],tokenAllowance:number){
 const limit=Math.min(48000,Math.floor(tokenAllowance*1.2));
 const selected=children.map(t=>({task:t,artifacts:t.artifacts.filter(a=>a.runId===t.runs.at(-1)?.id).slice(-3)}));
 const all=selected.flatMap(x=>x.artifacts),size=all.reduce((n,a)=>n+Buffer.byteLength(a.content),0),perArtifact=Math.floor(limit/Math.max(1,all.length));
 return selected.map(({task,artifacts})=>({title:task.title,status:task.status,artifacts:artifacts.map(a=>{const content=size<=limit?a.content:boundedText(a.content,perArtifact);return {name:a.name,hash:a.hash,content,truncated:content!==a.content};}),verifications:task.verifications.filter(v=>v.runId===task.runs.at(-1)?.id).map(v=>({criterionId:v.criterionId,passed:v.passed,environment:v.environment,evidence:boundedText(v.evidence,1500)}))}));
}
