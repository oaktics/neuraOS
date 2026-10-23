import {test} from 'node:test';
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {access,stat} from 'node:fs/promises';
import {dirname} from 'node:path';
import {fileURLToPath} from 'node:url';
import {ActivityTracker,activityArguments,activityBridge} from '../../apps/daemon/src/agent-activity.ts';

test('lifecycle tracks questions, parallel tools, answers, completion, and interruption',()=>{
  const tracker=new ActivityTracker();
  const event=(name:string,extra={})=>tracker.accept({hook_event_name:name,...extra});
  assert.equal(tracker.activity,'unknown');
  assert.equal(event('SessionStart'),'idle');
  assert.equal(event('UserPromptSubmit'),'working');
  assert.equal(event('PreToolUse',{tool_name:'request_user_input',tool_use_id:'question'}),'waiting');
  assert.equal(event('PreToolUse',{tool_name:'Bash',tool_use_id:'other'}),'waiting');
  assert.equal(event('PostToolUse',{tool_use_id:'other'}),'waiting');
  assert.equal(event('PostToolUse',{tool_use_id:'question'}),'working');
  assert.equal(event('PreToolUse',{tool_name:'AskUserQuestion',tool_use_id:'q2'}),'waiting');
  assert.equal(event('PostToolUseFailure',{tool_use_id:'q2'}),'working');
  assert.equal(event('Stop'),'idle');
  assert.equal(event('UserPromptSubmit'),'working');
  assert.equal(event('Interrupt'),'idle');
  tracker.interrupt();assert.equal(tracker.activity,'unknown');
  assert.equal(event('UserPromptSubmit'),'working');
  assert.equal(event('StopFailure'),'unknown');
});

test('approval and elicitation wait until the matching result; notifications do not imply completion',()=>{
  const tracker=new ActivityTracker();
  const event=(name:string,extra={})=>tracker.accept({hook_event_name:name,...extra});
  event('UserPromptSubmit');
  assert.equal(event('PermissionRequest',{tool_name:'Bash'}),'waiting');
  assert.equal(event('Notification',{notification_type:'idle_prompt'}),'waiting');
  assert.equal(event('PostToolUse',{tool_name:'Bash',tool_use_id:'p'}),'working');
  assert.equal(event('Elicitation'),'waiting');
  assert.equal(event('ElicitationResult'),'working');
  assert.equal(event('Notification',{notification_type:'permission_prompt'}),'waiting');
  assert.equal(event('PostToolUse',{tool_name:'Bash'}),'working');
});

test('subagents and other sessions cannot mark the root turn idle or replace its transcript',()=>{
  const tracker=new ActivityTracker();
  const root={session_id:'root',transcript_path:'/root.jsonl'};
  tracker.accept({...root,hook_event_name:'SessionStart',source:'startup'});
  tracker.accept({...root,hook_event_name:'UserPromptSubmit'});
  for(const child of [{...root,agent_id:'child'},{session_id:'other',transcript_path:'/other.jsonl'},{...root,transcript_path:'/subagent.jsonl'}]){
    tracker.accept({...child,hook_event_name:'SessionStart',source:'startup'});
    assert.equal(tracker.accept({...child,hook_event_name:'Stop'}),'working');
  }
  assert.equal(tracker.accept({...root,hook_event_name:'Stop'}),'idle');
  assert.equal(tracker.accept({...root,hook_event_name:'SessionStart',source:'compact'}),'working');
  assert.equal(tracker.accept({...root,hook_event_name:'SessionEnd'}),'unknown');
});

test('launch options preserve user config and never bypass hook trust',()=>{
  const command="'/path with space/node' '/hook.mjs'";
  const codex=activityArguments('codex',command);
  assert.ok(codex.includes('--no-daemon'));
  assert.ok(codex.some(arg=>arg.startsWith('hooks.PreToolUse=')));
  assert.ok(!codex.includes('--dangerously-bypass-hook-trust'));
  const claude=activityArguments('claude',command);
  assert.equal(claude[0],'--settings');
  assert.equal(JSON.parse(claude[1]).hooks.PreToolUse[0].hooks[0].command,command);
  assert.deepEqual(activityArguments('shell'),[]);
});

test('real hook helper delivers only whitelisted metadata to its own private socket and fails open',async()=>{
  const received:unknown[]=[];
  const bridge=await activityBridge(event=>received.push(event));
  const helper=fileURLToPath(new URL('../../apps/daemon/src/agent-activity-hook.mjs',import.meta.url));
  const invoke=async(path:string,payload:unknown)=>new Promise<{code:number|null;output:string}>((resolve,reject)=>{
    const child=spawn(process.execPath,[helper],{env:{...process.env,NEURA_ACTIVITY_SOCKET:path},stdio:['pipe','pipe','pipe']});
    let output='';child.stdout.on('data',data=>output+=data);child.stderr.on('data',data=>output+=data);
    child.on('error',reject);child.on('close',code=>resolve({code,output}));
    child.stdin.end(JSON.stringify(payload));
  });
  try{
    assert.equal((await stat(dirname(bridge.path))).mode&0o777,0o700);
    assert.deepEqual(await invoke(bridge.path,{hook_event_name:'PreToolUse',tool_name:'AskUserQuestion',tool_input:{secret:'never forward'},prompt:'private'}),{code:0,output:''});
    assert.deepEqual(received,[{hook_event_name:'PreToolUse',tool_name:'AskUserQuestion'}]);
    assert.deepEqual(await invoke('/tmp/nonexistent-neura-activity.sock',{}),{code:0,output:''});
  }finally{await bridge.close();}
  await assert.rejects(access(dirname(bridge.path)));
});

test('PTY sessions publish isolated activity revisions and discard activity on exit',async()=>{
  const {mkdtemp,writeFile,rm}=await import('node:fs/promises');
  const {tmpdir}=await import('node:os');
  const {join}=await import('node:path');
  const {Store}=await import('../../apps/daemon/src/store.ts');
  const {Terminals}=await import('../../apps/daemon/src/terminals.ts');
  const dir=await mkdtemp(join(tmpdir(),'neura-activity-pty-')),program=join(dir,'fake-claude.mjs');
  const previous=process.env.NEURA_CLAUDE_PATH;
  await writeFile(program,`#!/usr/bin/env node
import {createConnection} from 'node:net';
import {createInterface} from 'node:readline';
if(process.argv.includes('--help')){console.log('--settings');process.exit(0);}
if(process.argv.includes('--version')){console.log('2.1.307');process.exit(0);}
const emit=event=>new Promise(resolve=>{const socket=createConnection(process.env.NEURA_ACTIVITY_SOCKET);socket.on('error',resolve);socket.on('connect',()=>socket.end(JSON.stringify(event)+'\\n'));socket.on('close',resolve);});
await emit({hook_event_name:'SessionStart'});
for await(const line of createInterface({input:process.stdin})){
  if(line==='exit')process.exit(0);
  const event=line==='ask'?{hook_event_name:'PreToolUse',tool_name:'AskUserQuestion',tool_use_id:'q'}:line==='answer'?{hook_event_name:'PostToolUse',tool_use_id:'q'}:{hook_event_name:'Stop'};
  await emit(event);
}
`,{mode:0o700});
  process.env.NEURA_CLAUDE_PATH=program;
  const store=new Store(':memory:'),terminals=new Terminals(store);
  const waitFor=async(check:()=>boolean)=>{for(let i=0;i<100;i++){if(check())return;await new Promise(r=>setTimeout(r,20));}assert.fail('PTY state did not converge');};
  try{
    const workspace={id:'worktree',projectId:'p',name:'w',path:dir,branch:'main',kind:'worktree' as const,createdAt:''};
    const first=await terminals.open(workspace,'claude',false),second=await terminals.open(workspace,'claude',false);
    const record=(id:string)=>store.get<import('../../apps/daemon/src/contracts.ts').TerminalRecord>('terminals',id)!;
    await waitFor(()=>record(first.id).activity==='idle'&&record(second.id).activity==='idle');
    const revision=store.state().revision;
    terminals.input(first.id,'client','ask\r');await waitFor(()=>record(first.id).activity==='waiting');
    assert.ok(store.state().revision>revision);assert.equal(record(second.id).activity,'idle');
    terminals.input(first.id,'client','answer\r');await waitFor(()=>record(first.id).activity==='working');
    terminals.input(first.id,'client','exit\r');await waitFor(()=>record(first.id).status==='exited');
    assert.equal(record(first.id).activity,undefined);assert.equal(record(second.id).status,'running');
  }finally{await terminals.shutdown();store.close();if(previous===undefined)delete process.env.NEURA_CLAUDE_PATH;else process.env.NEURA_CLAUDE_PATH=previous;await rm(dir,{recursive:true,force:true});}
});

test('Codex child turn completion cannot stop a parent when transcript paths are absent',()=>{
  const tracker=new ActivityTracker();
  tracker.accept({hook_event_name:'SessionStart',session_id:'root',source:'startup'});
  tracker.accept({hook_event_name:'UserPromptSubmit',session_id:'root',turn_id:'parent'});
  assert.equal(tracker.accept({hook_event_name:'SessionStart',session_id:'root',source:'startup'}),'working');
  assert.equal(tracker.accept({hook_event_name:'Stop',session_id:'root',turn_id:'child'}),'working');
  assert.equal(tracker.accept({hook_event_name:'Stop',session_id:'root',turn_id:'parent'}),'idle');
});
