import { readFile,mkdir,writeFile } from 'node:fs/promises';
import { randomUUID } from 'node:crypto';
import { verifyCriterion } from '../packages/execution/src/verify.ts';
import { contentHash } from '../packages/policy/src/index.ts';
import type { Criterion,Artifact } from '../packages/contracts/src/index.ts';
interface Case {id:string;category:string;objective:string;content:string;kind:'contains'|'json';value:string;shouldPass:boolean}
const cases=JSON.parse(await readFile('tests/evaluations/cases.json','utf8')) as Case[];
const results=[];for(const c of cases){const a:Artifact={id:randomUUID(),name:c.kind==='json'?'result.json':'result.md',content:c.content,hash:contentHash(c.content),mediaType:c.kind==='json'?'application/json':'text/markdown',size:Buffer.byteLength(c.content),runId:randomUUID(),createdAt:new Date().toISOString(),cloudKey:null,cloudVerifiedAt:null};const criterion:Criterion={id:randomUUID(),kind:c.kind,value:c.value,description:c.objective,required:true};const v=await verifyCriterion(criterion,[a],'.tmp/evaluations',new AbortController().signal);results.push({id:c.id,category:c.category,expected:c.shouldPass,actual:v?.passed,passed:v?.passed===c.shouldPass});}
const report={mode:'deterministic-verifier-fixtures',at:new Date().toISOString(),realAgentEvaluations:0,taskCompletionRate:null,memoryImprovement:null,passed:results.filter(x=>x.passed).length,total:results.length,results};await mkdir('.tmp/evidence',{recursive:true});await writeFile('.tmp/evidence/evaluation.json',JSON.stringify(report,null,2));console.log(`${report.passed}/${report.total} verifier fixtures passed. Real agent completion rate: unmeasured.`);if(report.passed!==report.total)process.exitCode=1;
