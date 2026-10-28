import {test} from 'node:test';
import assert from 'node:assert/strict';
import {DatabaseSync} from 'node:sqlite';
import {mkdtemp,mkdir,writeFile,appendFile,rm,realpath} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {randomUUID} from 'node:crypto';
import {codexSessionName,claudeSessionName,SessionNames} from '../../apps/daemon/src/session-names.ts';
import {Store} from '../../apps/daemon/src/store.ts';
import type {Workspace,TerminalRecord} from '../../apps/daemon/src/contracts.ts';

test('Codex uses generated conversation names, scoped to the exact worktree and main CLI session',async()=>{
  const home=await mkdtemp(join(tmpdir(),'neura-codex-names-')),path='/repo/worktree';
  const db=new DatabaseSync(join(home,'state_5.sqlite'));
  try {
    db.exec('CREATE TABLE threads(id TEXT PRIMARY KEY, cwd TEXT, name TEXT, title TEXT, source TEXT, archived INTEGER, updated_at INTEGER, updated_at_ms INTEGER)');
    const insert=db.prepare('INSERT INTO threads VALUES(?,?,?,?,?,?,?,?)');
    insert.run('main',path,'ログイン画面の改善','Raw initial prompt','cli',0,1,1001);
    insert.run('other','/repo/worktree-other','別の作業','other','cli',0,2,2000);
    insert.run('child',path,'子エージェント','child','subagent',0,3,3000);
    insert.run('archived',path,'アーカイブ','archived','cli',1,4,4000);
    assert.deepEqual(await codexSessionName(path,home),{name:'ログイン画面の改善',updatedAt:1001});
    db.prepare('UPDATE threads SET name=? WHERE id=?').run('更新された会話名','main');
    assert.equal((await codexSessionName(path,home))?.name,'更新された会話名');
    insert.run('new',path,null,'Never use the first prompt','cli',0,5,null);
    assert.equal(await codexSessionName(path,home),undefined);
    assert.equal((await codexSessionName(path,home,'main'))?.name,'更新された会話名');
    assert.equal(await codexSessionName(path,home,'missing'),undefined);
    assert.equal(await codexSessionName('/unrelated',home),undefined);
    insert.run('managed',path,'監督された会話','Raw task','appServer',0,6,6000);
    assert.equal(await codexSessionName(path,home),undefined);
    assert.equal((await codexSessionName(path,home,'managed'))?.name,'監督された会話');
    assert.equal(db.prepare('SELECT COUNT(*) AS n FROM threads').get()?.n,6);
  } finally {db.close();await rm(home,{recursive:true,force:true});}
});

test('Claude reads actual ai-title and custom-title JSONL metadata without using the prompt',async()=>{
  const home=await mkdtemp(join(tmpdir(),'neura-claude-names-')),previous=process.env.CLAUDE_CONFIG_DIR;
  process.env.CLAUDE_CONFIG_DIR=home;
  try {
    const path=join(await realpath(home),'worktree'),sessionId=randomUUID();await mkdir(path);
    const project=join(home,'projects',path.replace(/[^a-zA-Z0-9]/g,'-'));await mkdir(project,{recursive:true});
    const transcript=join(project,`${sessionId}.jsonl`);
    await writeFile(transcript,JSON.stringify({type:'user',sessionId,cwd:path,isSidechain:false,uuid:randomUUID(),timestamp:new Date().toISOString(),message:{role:'user',content:'A raw prompt that must not be the workspace name'}})+'\n');
    assert.equal(await claudeSessionName(path),undefined);
    await appendFile(transcript,JSON.stringify({type:'ai-title',sessionId,aiTitle:'通知の表示を改善'})+'\n');
    assert.equal((await claudeSessionName(path))?.name,'通知の表示を改善');
    await appendFile(transcript,JSON.stringify({type:'custom-title',sessionId,customTitle:'新しい会話名'})+'\n');
    assert.equal((await claudeSessionName(path))?.name,'新しい会話名');
    assert.equal(await claudeSessionName(join(home,'other')),undefined);
  } finally {
    if(previous===undefined)delete process.env.CLAUDE_CONFIG_DIR;else process.env.CLAUDE_CONFIG_DIR=previous;
    await rm(home,{recursive:true,force:true});
  }
});

test('Claude excludes sibling worktrees, programmatic sessions and encoded-path collisions',async()=>{
  const name=await claudeSessionName('/repo/a-b',async options=>{
    assert.deepEqual(options,{dir:'/repo/a-b',includeWorktrees:false,includeProgrammatic:false});
    return [
      {sessionId:'wrong',cwd:'/repo/a/b',customTitle:'別worktree',summary:'別worktree',lastModified:2000},
      {sessionId:'right',cwd:'/repo/a-b',customTitle:'正しい会話',summary:'正しい会話',lastModified:1000},
    ];
  });
  assert.equal(name?.name,'正しい会話');
});

test('workspace names follow the latest provider conversation, persist, and never rename paths or root folders',async()=>{
  const home=await mkdtemp(join(tmpdir(),'neura-workspace-names-')),dbPath=join(home,'store.sqlite');
  let store=new Store(dbPath);
  const workspace:Workspace={id:randomUUID(),projectId:randomUUID(),name:'worktree-placeholder',path:'/repo/worktree',branch:'neura/worktree-placeholder',kind:'worktree',createdAt:new Date().toISOString()};
  const terminal=(workspaceId:string,provider:TerminalRecord['provider']):TerminalRecord=>({id:randomUUID(),workspaceId,provider,status:'running',createdAt:new Date().toISOString(),cols:100,rows:30});
  try {
    const root={...workspace,id:randomUUID(),kind:'root' as const,name:'メイン',path:'/repo'};
    const shell={...workspace,id:randomUUID(),name:'shell-only',path:'/repo/shell'};
    for(const w of [workspace,root,shell])store.put('workspaces',w);
    for(const t of [terminal(workspace.id,'codex'),terminal(workspace.id,'claude'),terminal(root.id,'codex'),terminal(shell.id,'shell')])store.put('terminals',t);
    let codex={name:'Codexの会話名',updatedAt:1000},claude:{name:string;updatedAt:number}|undefined={name:'Claudeの会話名',updatedAt:2000};
    const names=new SessionNames(store,{
      codex:async path=>{assert.equal(path,workspace.path);return codex;},
      claude:async path=>{assert.equal(path,workspace.path);return claude;},
    },0);
    await names.refresh();
    assert.deepEqual(store.get('workspaces',workspace.id),{...workspace,name:'Claudeの会話名'});
    const revision=store.state().revision;
    await names.refresh();assert.equal(store.state().revision,revision);
    codex={name:'Codexの新しい会話名',updatedAt:3000};await names.refresh();
    assert.equal(store.get<Workspace>('workspaces',workspace.id)?.name,codex.name);
    claude=undefined;await names.refresh();
    assert.equal(store.get<Workspace>('workspaces',root.id)?.name,'メイン');
    assert.equal(store.get<Workspace>('workspaces',shell.id)?.name,'shell-only');
    const unavailable=new SessionNames(store,{codex:async()=>{throw new Error('unsupported schema');},claude:async()=>undefined},0);
    await unavailable.refresh();
    assert.equal(store.get<Workspace>('workspaces',workspace.id)?.name,codex.name);
    await names.close();store.close();store=new Store(dbPath);
    assert.deepEqual(store.get('workspaces',workspace.id),{...workspace,name:codex.name});
  } finally {store.close();await rm(home,{recursive:true,force:true});}
});

test('only running or newly stopped CLIs read history; stopped worktrees and daemon restarts stay idle',async()=>{
  const store=new Store(':memory:');
  const workspace:Workspace={id:randomUUID(),projectId:randomUUID(),name:'保存済みの名前',path:'/repo/active',branch:'neura/active',kind:'worktree',createdAt:new Date().toISOString()};
  const terminal=(workspaceId:string,provider:TerminalRecord['provider'],status:TerminalRecord['status']):TerminalRecord=>({id:randomUUID(),workspaceId,provider,status,createdAt:new Date().toISOString(),cols:100,rows:30});
  try {
    store.put('workspaces',workspace);
    // Historical worktrees must cost zero provider reads, not one scan each per poll.
    for(let i=0;i<50;i++){
      const old={...workspace,id:randomUUID(),path:`/repo/old-${i}`};store.put('workspaces',old);
      store.put('terminals',terminal(old.id,'claude',i%2?'exited':'interrupted'));
    }
    store.put('terminals',terminal(workspace.id,'claude','exited'));
    let codexReads=0,claudeReads=0,failClaude=false;
    let codexTitle={name:'Codexの名前',updatedAt:1000},claudeTitle={name:'Claudeの名前',updatedAt:2000};
    const readers={
      codex:async(path:string)=>{assert.equal(path,workspace.path);codexReads++;return codexTitle;},
      claude:async(path:string)=>{assert.equal(path,workspace.path);claudeReads++;if(failClaude)throw new Error('unavailable');return claudeTitle;},
    };
    const names=new SessionNames(store,readers,0);
    for(let i=0;i<5;i++)await names.refresh();
    assert.equal(claudeReads,0);assert.equal(codexReads,0);
    const claude=terminal(workspace.id,'claude','running'),codex=terminal(workspace.id,'codex','running');
    store.put('terminals',claude);store.put('terminals',codex);
    await Promise.all([names.refresh(),names.refresh()]);
    assert.equal(claudeReads,1);assert.equal(codexReads,1);
    assert.equal(store.get<Workspace>('workspaces',workspace.id)?.name,claudeTitle.name);
    claudeTitle={name:'終了直前のClaudeの名前',updatedAt:3000};
    store.put('terminals',{...claude,status:'exited'});
    await names.refresh();assert.equal(claudeReads,2);
    for(let i=0;i<5;i++)await names.refresh();
    assert.equal(claudeReads,2);
    assert.equal(store.get<Workspace>('workspaces',workspace.id)?.name,claudeTitle.name);
    codexTitle={name:'更新されたCodexの名前',updatedAt:4000};
    await names.refresh();assert.equal(store.get<Workspace>('workspaces',workspace.id)?.name,codexTitle.name);
    store.put('terminals',{...codex,status:'interrupted'});await names.refresh();
    const stoppedCodexReads=codexReads;
    for(let i=0;i<5;i++)await names.refresh();
    assert.equal(codexReads,stoppedCodexReads);assert.equal(claudeReads,2);
    // A daemon restart does not schedule historical terminal reads again.
    const restarted=new SessionNames(store,readers,0);
    await restarted.refresh();assert.equal(codexReads,stoppedCodexReads);assert.equal(claudeReads,2);
    assert.equal(store.get<Workspace>('workspaces',workspace.id)?.name,codexTitle.name);
    // Even a CLI that starts and exits between polls gets one final read.
    claudeTitle={name:'短い会話の名前',updatedAt:5000};
    store.put('terminals',terminal(workspace.id,'claude','exited'));
    await restarted.refresh();assert.equal(claudeReads,3);
    assert.equal(store.get<Workspace>('workspaces',workspace.id)?.name,claudeTitle.name);
    await restarted.refresh();assert.equal(claudeReads,3);
    // A failed final read is bounded too; existing names remain usable.
    failClaude=true;store.put('terminals',terminal(workspace.id,'claude','exited'));
    await restarted.refresh();await restarted.refresh();assert.equal(claudeReads,4);
    assert.equal(store.get<Workspace>('workspaces',workspace.id)?.name,claudeTitle.name);
    // Starting a new CLI after idle resumes polling and picks up a new title.
    failClaude=false;claudeTitle={name:'再開後の名前',updatedAt:6000};
    store.put('terminals',terminal(workspace.id,'claude','running'));
    await restarted.refresh();await restarted.refresh();assert.equal(claudeReads,6);
    assert.equal(store.get<Workspace>('workspaces',workspace.id)?.name,claudeTitle.name);
    await names.close();await restarted.close();
  } finally {store.close();}
});


test('tab names follow exact sessions, including root folders, and preserve concurrent record updates',async()=>{
  const store=new Store(':memory:');
  const workspace:Workspace={id:'w',projectId:'p',name:'Root',path:'/repo',branch:'main',kind:'root',createdAt:''};
  const terminal=(id:string):TerminalRecord=>({id,workspaceId:'w',provider:'codex',sessionId:id,status:'running',createdAt:'',cols:100,rows:30});
  try {
    store.put('workspaces',workspace);
    store.put('terminals',terminal('first'));store.put('terminals',terminal('second'));
    store.put('terminals',{...terminal('unbound'),sessionId:undefined});
    const names=new SessionNames(store,{
      codex:async(path,id)=>{
        assert.equal(path,'/repo');
        assert.ok(id);
        const current=store.get<TerminalRecord>('terminals',id)!;
        store.put('terminals',{...current,cols:120});
        return {name:'作業 '+id,updatedAt:1};
      },
      claude:async()=>undefined,
    },0);
    await names.refresh();
    assert.equal(store.get<TerminalRecord>('terminals','first')?.sessionName,'作業 first');
    assert.equal(store.get<TerminalRecord>('terminals','second')?.sessionName,'作業 second');
    assert.equal(store.get<TerminalRecord>('terminals','first')?.cols,120);
    assert.equal(store.get<TerminalRecord>('terminals','unbound')?.sessionName,undefined);
    assert.equal(store.get<Workspace>('workspaces','w')?.name,'Root');
    await names.close();
  } finally {store.close();}
});
