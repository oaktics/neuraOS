import {reviewReserve,spentTokens,spentCalls} from './budget.ts';
import {randomUUID} from 'node:crypto';
import {TaskInput,type State,type Task,type Command,type Actor} from '../../contracts/src/index.ts';
import {ensure,assertProvider} from '../../policy/src/index.ts';
import {makePlan} from './index.ts';

export function addTask(s:State,id:string,input:TaskInput,at:string,work?:Task['work']):Task{
  ensure(!s.tasks.some(t=>t.id===id),'task_exists');const task:Task={...input,id,workspaceId:s.workspaceId,version:1,requirementsVersion:1,status:'draft',reason:'',createdAt:at,updatedAt:at,plans:[makePlan(input,1,1,at)],runs:[],events:[],artifacts:[],verifications:[],actions:[],approvals:[],...(work?{work}:{})};s.tasks.unshift(task);return task;
}
export function handleOrganization(s:State,c:Command,actor:Actor,at:string,t?:Task){
  s.conversations??=[];
  if(c.type==='chat.send'){
    const project=c.projectId?s.projects.find(p=>p.id===c.projectId):undefined;ensure(!c.projectId||project,'project_not_found');ensure(project?.classification!=='local-only','local_only');
    let conversation=s.conversations.find(x=>x.id===c.conversationId);
    if(conversation){ensure(conversation.projectId===c.projectId,'conversation_scope');ensure(!conversation.messages.some(m=>m.role==='user'&&s.tasks.some(t=>t.id===m.taskId&&['queued','running','verifying'].includes(t.status))),'conversation_busy');}
    else {conversation={id:c.conversationId,projectId:c.projectId,provider:c.provider,messages:[],createdAt:at};s.conversations.push(conversation);}
    const provider=project?.provider??c.provider;conversation.provider=provider;
    const input=TaskInput.parse({title:c.content.slice(0,80),objective:c.content,provider,projectId:c.projectId,classification:project?.classification??'standard',allowedProviders:[provider],criteria:[{id:randomUUID(),description:'相談への構造化された回答',kind:'json',value:'',required:true}],budget:{maxSeconds:300,maxCalls:4,maxTokens:30000,maxUsd:null}});
    const task=addTask(s,c.id,input,at,{role:project?'director_chat':'vice_president',parentId:null,conversationId:conversation.id,phase:'chat',title:project?'部長':'副社長'});assertProvider(task);task.status='queued';
    conversation.messages.push({id:randomUUID(),role:'user',content:c.content,taskId:task.id,createdAt:at,proposals:[]});
  }
  if(c.type==='chat.result'){
    ensure(t?.work?.phase==='chat','not_chat');const conv=s.conversations.find(x=>x.id===t.work!.conversationId);ensure(conv,'conversation_missing');ensure(!conv.messages.some(m=>m.role==='assistant'&&m.taskId===t.id),'chat_already_answered');
    for(const proposal of c.reply.proposals){const project=s.projects.find(p=>p.id===proposal.projectId);ensure(project&&project.classification!=='local-only','project_not_found');ensure(conv.projectId?project.id===conv.projectId:project.classification==='standard','project_scope');}
    conv.messages.push({id:randomUUID(),role:'assistant',content:c.reply.reply,taskId:t.id,createdAt:at,proposals:c.reply.proposals});
  }
  if(c.type==='chat.delegate'){
    const conv=s.conversations.find(x=>x.id===c.conversationId),message=conv?.messages.find(m=>m.id===c.messageId&&m.role==='assistant'),proposal=message?.proposals[c.proposalIndex];ensure(conv&&message&&proposal,'proposal_missing');ensure(!proposal.taskId,'already_delegated');
    const project=s.projects.find(p=>p.id===proposal.projectId);ensure(project&&project.classification!=='local-only','project_not_found');ensure(conv.projectId?project.id===conv.projectId:project.classification==='standard','project_scope');
    const provider=project.provider??'codex';const input=TaskInput.parse({title:proposal.title,objective:proposal.objective,projectId:project.id,provider,allowedProviders:[provider],classification:project.classification,constraints:`部長として社員の成果物を集約する。必要な成果物: ${proposal.deliverable}`,criteria:[{id:randomUUID(),kind:'artifact',description:proposal.deliverable,value:'',required:true},{id:randomUUID(),kind:'human',description:'社長が集約された成果物を受け入れる',value:'',required:true}],budget:{maxSeconds:1200,maxCalls:18,maxTokens:150000,maxUsd:null}});
    const task=addTask(s,c.id,input,at,{role:'director',parentId:null,conversationId:conv.id,phase:'planning',title:`${project.name} 部長`});assertProvider(task);task.status='queued';proposal.taskId=task.id;
  }
  if(c.type==='team.plan'){
    ensure(t?.work?.role==='director'&&t.work.phase==='planning','invalid_team_phase');ensure(!s.tasks.some(x=>x.work?.parentId===t.id),'team_already_planned');const project=s.projects.find(p=>p.id===t.projectId);ensure(project,'project_not_found');ensure(c.plan.assignments.length<=(project.maxWorkers??3),'team_size_exceeded');
    const shares=c.plan.assignments.length+2;ensure(t.budget.maxCalls>=shares,'call_budget');
    const employeeTokens=Math.floor((t.budget.maxTokens-spentTokens(t)-reviewReserve(t))/c.plan.assignments.length);ensure(employeeTokens>=100,'team_token_budget');
    for(const assignment of c.plan.assignments){const child=addTask(s,randomUUID(),TaskInput.parse({...t,title:assignment.title,objective:assignment.objective,constraints:`${t.constraints}\n担当成果物: ${assignment.output}\n他の社員の担当には介入せず、未確認事項を明示する。`,criteria:[{id:randomUUID(),kind:'artifact',description:assignment.output,value:'',required:true}],budget:{...t.budget,maxCalls:Math.floor(t.budget.maxCalls/shares),maxTokens:employeeTokens}}),at,{role:'employee',parentId:t.id,conversationId:t.work.conversationId,phase:'work',title:assignment.title,sourcePaths:assignment.sourcePaths});child.status='queued';}
    t.work.phase='waiting';t.status='blocked';t.reason='waiting_team';t.runs.at(-1)!.status='blocked';t.runs.at(-1)!.reason='waiting_team';
  }
  if(c.type==='team.review.resume'){
    ensure(t?.work?.role==='director'&&t.work.phase==='reviewing'&&['blocked','paused'].includes(t.status),'invalid_team_phase');
    const children=s.tasks.filter(x=>x.work?.parentId===t.id);ensure(children.length>0&&children.every(x=>x.status==='succeeded'),'team_incomplete');
    ensure([t,...children].every(x=>!x.actions.some(a=>['unknown','dispatching','proposed'].includes(a.status))),'unresolved_action');
    ensure(t.runs.every(r=>Date.parse(r.leaseUntil)<=Date.parse(at)),'lease_held');
    const tokens=[t,...children].reduce((n,x)=>n+spentTokens(x),0),calls=[t,...children].reduce((n,x)=>n+spentCalls(x),0);
    t.budget.maxTokens=Math.max(t.budget.maxTokens,tokens+c.additionalTokens);t.budget.maxCalls=Math.max(t.budget.maxCalls,calls+3);
    const last=t.runs.at(-1);if(last)last.endedAt=at;t.status='queued';t.reason='review_resume_requested';
  }
  if(c.type==='team.reviewed'){ensure(t?.work?.role==='director'&&t.work.phase==='reviewing','invalid_team_phase');ensure(s.tasks.filter(x=>x.work?.parentId===t.id).every(x=>x.status==='succeeded'),'team_incomplete');t.work.phase='finished';}
}
export function refreshTeams(s:State,at:string){
  for(const task of s.tasks.filter(t=>t.work?.role==='director'&&t.work.phase==='waiting'&&t.status==='blocked')){
    const children=s.tasks.filter(t=>t.work?.parentId===task.id);if(!children.length)continue;
    if(children.every(t=>t.status==='succeeded')){task.work!.phase='reviewing';task.status='queued';task.reason='team_ready';task.version++;task.updatedAt=at;}
    else if(children.some(t=>['failed','blocked','canceled','needs_revision'].includes(t.status))&&task.reason!=='team_member_blocked'){task.reason='team_member_blocked';task.version++;task.updatedAt=at;}
  }
}
