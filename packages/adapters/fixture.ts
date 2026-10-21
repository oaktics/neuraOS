import type { AgentAdapter, AdapterContext, Capabilities } from './index.ts';
/** Explicit deterministic fixture, never a fallback for real provider failure. */
export class FixtureAdapter implements AgentAdapter {
  async probeCapabilities():Promise<Capabilities>{return {provider:'fixture',available:true,resume:false,interrupt:true,structuredOutput:true,usage:false,approvals:false,isolation:true,version:'fixture/1',reason:'テスト専用。AI・実サービスの成功証拠にはなりません。'};}
  async execute(c:AdapterContext){c.signal.throwIfAborted();await c.onSession('fixture-'+c.task.id,'fixture','fixture/1');await c.onEvent('fixture.generated','固定データによる検証用の成果物です。');
    const context=c.organization as {projects?:{id:string}[]}|undefined;
    if(['vice_president','director_chat'].includes(c.task.work?.role??'')){
      const reply='## 進め方\n\nこれは**固定fixture**の相談応答です。目的を整理し、担当プロジェクトへ提案します。\n\n| 担当 | 内容 |\n| --- | --- |\n| 社員1 | 選択肢を整理 |\n| 社員2 | 懸念点を確認 |\n\n```typescript\nconst team = ["社員1", "社員2"];\n```\n\n$$1 + 1 = 2$$\n\n```mermaid\nflowchart LR\n  A[副社長] --> B[部長]\n  B --> C[社員1]\n  B --> D[社員2]\n```';
      for(let end=40;end<reply.length;end+=80){await c.onText?.(reply.slice(0,end));await new Promise(r=>setTimeout(r,180));c.signal.throwIfAborted();}
      return {output:{summary:'固定fixtureの相談応答',artifacts:[{name:'response.json',mediaType:'application/json' as const,content:JSON.stringify({reply,proposals:context?.projects?.[0]?[{projectId:context.projects[0].id,title:'比較資料の作成',objective:'二つの視点から比較資料を作成し集約する',deliverable:'根拠を明示した比較メモ'}]:[]})}],memoryCandidates:[]},tokens:0,costUsd:0,calls:1};
    }
    if(c.task.work?.role==='director'&&c.task.work.phase==='planning')return {output:{summary:'固定fixtureの分担計画',artifacts:[{name:'team-plan.json',mediaType:'application/json' as const,content:JSON.stringify({summary:'二人に分担',assignments:[{title:'選択肢を整理',objective:'選択肢を比較する',output:'比較メモ'},{title:'懸念点を確認',objective:'不明点を明示する',output:'確認メモ'}]})}],memoryCandidates:[]},tokens:0,costUsd:0,calls:1};
    return {output:{summary:'固定fixtureによる検証',artifacts:[{name:'result.md',mediaType:'text/markdown' as const,content:`# ${c.task.title}\n\n${c.task.objective}\n\nこれは固定fixtureです。AIによる実行ではありません。\n`}],memoryCandidates:[]},tokens:0,costUsd:0,calls:1};}
}
