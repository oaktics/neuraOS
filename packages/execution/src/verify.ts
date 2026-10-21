import type { Artifact, Criterion } from '../../contracts/src/index.ts';
import { contentHash } from '../../policy/src/index.ts';
import { runNodeTest } from './sandbox.ts';
export async function verifyCriterion(c:Criterion,artifacts:Artifact[],workdir:string,signal:AbortSignal):Promise<{passed:boolean;evidence:string;environment:'local'|'container'}|null>{
  const intact=artifacts.length>0&&artifacts.every(a=>contentHash(a.content)===a.hash&&Buffer.byteLength(a.content)===a.size);
  if(c.kind==='human')return null;
  if(c.kind==='artifact')return {passed:intact,evidence:intact?artifacts.map(a=>`${a.name}: sha256=${a.hash}, bytes=${a.size}`).join('\n'):'成果物なし、またはハッシュ不一致',environment:'local'};
  if(c.kind==='contains'){const passed=intact&&c.value.length>0&&artifacts.some(a=>a.content.includes(c.value));return {passed,evidence:passed?'指定された文字列の存在を確認':'指定された文字列が見つかりません',environment:'local'};}
  if(c.kind==='json'){let passed=false;try{passed=intact&&artifacts.filter(a=>a.mediaType==='application/json').some(a=>{JSON.parse(a.content);return true;});}catch{}return {passed,evidence:passed?'JSON.parse で妥当性を確認':'JSON成果物がないか構文エラー',environment:'local'};}
  const a=artifacts.find(a=>a.mediaType==='text/javascript');if(!a)return {passed:false,evidence:'JavaScript成果物がありません',environment:'container'};
  const result=await runNodeTest(a.content,c.value,workdir,signal);return {...result,environment:'container'};
}
