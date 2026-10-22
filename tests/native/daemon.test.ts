import {test} from 'node:test';
import assert from 'node:assert/strict';
import {mkdtemp,mkdir,writeFile,readFile,symlink,rm,stat} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {randomUUID} from 'node:crypto';
import {createDaemon} from '../../apps/daemon/src/server.ts';
import {git} from '../../apps/daemon/src/workspace.ts';
import {argumentsFor} from '../../apps/daemon/src/terminals.ts';

test('daemon: worktrees, authenticated commands, durable PTY, reconnect and conflicts',async()=>{
  const root=await mkdtemp(join(tmpdir(),'neura-native-')),repo=join(root,'repo'),data=join(root,'data');await mkdir(repo);
  await git(repo,['init','-b','main']);await git(repo,['config','user.name','Test']);await git(repo,['config','user.email','test@example.invalid']);
  await writeFile(join(repo,'hello.txt'),'hello\n');await git(repo,['add','.']);await git(repo,['commit','-m','initial']);
  let daemon=await createDaemon(data);
  const get=async(path:string)=>daemon.app.inject({method:'GET',url:path,headers:{authorization:`Bearer ${daemon.token}`}});
  const cmd=async(command:unknown,operationId=randomUUID())=>daemon.app.inject({method:'POST',url:'/v1/commands',headers:{authorization:`Bearer ${daemon.token}`},payload:{operationId,command}});
  try {
    assert.equal((await daemon.app.inject('/v1/state')).statusCode,401);
    assert.equal((await daemon.app.inject({url:'/v1/state',headers:{authorization:`Bearer ${daemon.token}`,origin:'https://evil.invalid'}})).statusCode,401);
    assert.equal((await stat(join(data,'daemon-token'))).mode&0o777,0o600);
    const project=(await cmd({type:'project.add',path:repo})).json();assert.ok(project.id);
    const op=randomUUID(),command={type:'workspace.create',projectId:project.id};
    const [a,b]=await Promise.all([cmd(command,op),cmd(command,op)]);assert.equal(a.statusCode,200);assert.equal(b.statusCode,200);assert.equal(a.json().id,b.json().id);
    const ws=a.json();assert.notEqual(ws.path,repo);assert.match(await git(repo,['worktree','list']),new RegExp(ws.branch));
    assert.equal(ws.name,`worktree-${op.slice(0,8)}`);assert.equal(ws.branch,`neura/${ws.name}`);assert.equal(b.json().name,ws.name);
    assert.equal((await cmd({...command,name:'different'},op)).statusCode,409);
    const other=(await cmd({...command,name:'Parallel two'})).json();assert.notEqual(other.path,ws.path);assert.equal(other.name,'Parallel two');
    const file=(await get(`/v1/workspaces/${ws.id}/file?path=hello.txt`)).json();
    assert.equal((await cmd({type:'file.save',workspaceId:ws.id,path:'hello.txt',content:'edited\n',expectedHash:file.hash})).statusCode,200);
    assert.equal(await readFile(join(repo,'hello.txt'),'utf8'),'hello\n');
    assert.equal(await readFile(join(other.path,'hello.txt'),'utf8'),'hello\n');
    assert.equal((await cmd({type:'file.save',workspaceId:ws.id,path:'hello.txt',content:'stale',expectedHash:file.hash})).statusCode,409);
    const changes=(await get(`/v1/workspaces/${ws.id}/git`)).json();assert.equal(changes.changes[0].path,'hello.txt');
    assert.match((await get(`/v1/workspaces/${ws.id}/diff?path=hello.txt`)).json().content,/\+edited/);
    await symlink(root,join(ws.path,'escape'));
    assert.equal((await get(`/v1/workspaces/${ws.id}/files?path=escape`)).statusCode,400);
    assert.equal((await get(`/v1/workspaces/${ws.id}/file?path=..%2Fdata%2Fdaemon-token`)).statusCode,400);
    assert.equal((await get(`/v1/workspaces/${ws.id}/file?path=.git`)).statusCode,400);
    const terminal=(await cmd({type:'terminal.open',workspaceId:ws.id,provider:'shell'})).json();assert.ok(terminal.id);
    const again=(await cmd({type:'terminal.open',workspaceId:ws.id,provider:'shell'})).json();assert.equal(again.id,terminal.id);
    const clientId=randomUUID(),inputId=randomUUID();
    const input={type:'terminal.input',terminalId:terminal.id,clientId,data:"printf 'persistent-output\\n'; printf x >> once.txt\n"};
    assert.equal((await cmd(input,inputId)).statusCode,200);assert.equal((await cmd(input,inputId)).statusCode,200);
    assert.equal((await cmd({...input,clientId:randomUUID()})).statusCode,409);
    let output:any;
    for(let i=0;i<60;i++){output=(await get(`/v1/terminals/${terminal.id}/output?after=0`)).json();if(await readFile(join(ws.path,'once.txt'),'utf8').then(s=>s==='x',()=>false))break;await new Promise(r=>setTimeout(r,50));}
    assert.equal(await readFile(join(ws.path,'once.txt'),'utf8'),'x');assert.match(output.data,/persistent-output/);
    const reconnect=(await get(`/v1/terminals/${terminal.id}/output?after=0`)).json();assert.ok(reconnect.cursor>=output.cursor);assert.match(reconnect.data,/persistent-output/);
    const events=(await get('/v1/events?after=0')).json().events;assert.ok(events.length>0);
    const token=daemon.token;await daemon.app.close();daemon=await createDaemon(data);assert.equal(daemon.token,token);
    const state=(await get('/v1/state')).json();assert.equal(state.workspaces.length,3);assert.equal(state.terminals[0].status,'interrupted');
    assert.equal(state.workspaces.find((w:any)=>w.id===ws.id).name,ws.name);
    assert.match((await get(`/v1/terminals/${terminal.id}/output?after=0`)).json().data,/persistent-output/);
    assert.equal((await cmd({type:'terminal.input',terminalId:terminal.id,clientId,data:'x'})).statusCode,404);
  } finally {await daemon.app.close();await rm(root,{recursive:true,force:true});}
});

test('provider commands default to full access for new sessions and resume choosers',()=>{
  assert.deepEqual(argumentsFor('codex',false),['--sandbox','danger-full-access','--ask-for-approval','never']);
  assert.deepEqual(argumentsFor('codex',true),['resume','--sandbox','danger-full-access','--ask-for-approval','never']);
  assert.deepEqual(argumentsFor('claude',false),['--permission-mode','bypassPermissions']);
  assert.deepEqual(argumentsFor('claude',true),['--resume','--permission-mode','bypassPermissions']);
  assert.deepEqual(argumentsFor('shell',false),['-l']);
  assert.deepEqual(argumentsFor('shell',true),['-l']);
});

test('ordinary folders support files, PTY and persistence without initializing Git',async()=>{
  const root=await mkdtemp(join(tmpdir(),'neura-folder-')),folder=join(root,'documents'),data=join(root,'data');
  await mkdir(folder);await writeFile(join(folder,'notes.txt'),'original\n');
  let daemon=await createDaemon(data);
  const get=(path:string)=>daemon.app.inject({url:path,headers:{authorization:`Bearer ${daemon.token}`}});
  const cmd=(command:unknown)=>daemon.app.inject({method:'POST',url:'/v1/commands',headers:{authorization:`Bearer ${daemon.token}`},payload:{operationId:randomUUID(),command}});
  try {
    const added=await cmd({type:'project.add',path:folder});assert.equal(added.statusCode,200);
    const project=added.json();assert.equal(project.isGit,false);
    const ws=(await get('/v1/state')).json().workspaces[0];assert.equal(ws.kind,'folder');assert.equal(ws.path,project.path);assert.equal(ws.branch,'');
    const again=(await cmd({type:'project.add',path:folder})).json();assert.equal(again.id,project.id);
    assert.equal((await get('/v1/state')).json().workspaces.length,1);
    assert.equal((await cmd({type:'workspace.create',projectId:project.id,name:'not a worktree'})).json().error,'git_required');
    assert.equal((await get(`/v1/workspaces/${ws.id}/git`)).json().error,'git_required');
    assert.equal((await get(`/v1/workspaces/${ws.id}/diff?path=notes.txt`)).json().error,'git_required');
    assert.equal((await get(`/v1/workspaces/${ws.id}/files`)).json().entries[0].name,'notes.txt');
    const original=(await get(`/v1/workspaces/${ws.id}/file?path=notes.txt`)).json();
    assert.equal((await cmd({type:'file.save',workspaceId:ws.id,path:'notes.txt',content:'編集済み\n',expectedHash:original.hash})).statusCode,200);
    assert.equal(await readFile(join(folder,'notes.txt'),'utf8'),'編集済み\n');
    assert.equal((await get(`/v1/workspaces/${ws.id}/file?path=..%2Fdata%2Fdaemon-token`)).statusCode,400);
    assert.equal((await cmd({type:'project.add',path:join(folder,'notes.txt')})).json().error,'not_directory');
    const terminal=(await cmd({type:'terminal.open',workspaceId:ws.id,provider:'shell'})).json();assert.ok(terminal.id);
    assert.equal((await cmd({type:'terminal.input',terminalId:terminal.id,clientId:randomUUID(),data:"printf folder-ok > shell-check.txt\n"})).statusCode,200);
    for(let i=0;i<60;i++){if(await readFile(join(folder,'shell-check.txt'),'utf8').then(s=>s==='folder-ok',()=>false))break;await new Promise(r=>setTimeout(r,50));}
    assert.equal(await readFile(join(folder,'shell-check.txt'),'utf8'),'folder-ok');
    await assert.rejects(stat(join(folder,'.git')),{code:'ENOENT'});
    await daemon.app.close();daemon=await createDaemon(data);
    const restored=(await get('/v1/state')).json();assert.equal(restored.projects[0].isGit,false);assert.equal(restored.workspaces[0].id,ws.id);assert.equal(restored.workspaces[0].kind,'folder');
    // Explicitly initializing later and reopening upgrades the same project/workspace.
    await git(folder,['init','-b','main']);
    const upgraded=(await cmd({type:'project.add',path:folder})).json();assert.equal(upgraded.id,project.id);assert.equal(upgraded.isGit,true);
    const state=(await get('/v1/state')).json();assert.equal(state.workspaces.length,1);assert.equal(state.workspaces[0].id,ws.id);assert.equal(state.workspaces[0].kind,'root');
  } finally {await daemon.app.close();await rm(root,{recursive:true,force:true});}
});

test('worktree deletion protects active work and removes persisted records while retaining branches',async()=>{
  const root=await mkdtemp(join(tmpdir(),'neura-delete-')),repo=join(root,'repo'),data=join(root,'data');
  await mkdir(repo);await git(repo,['init','-b','main']);await git(repo,['config','user.name','Test']);await git(repo,['config','user.email','test@example.invalid']);
  await writeFile(join(repo,'hello.txt'),'hello\n');await git(repo,['add','.']);await git(repo,['commit','-m','initial']);
  let daemon=await createDaemon(data);
  const cmd=(command:unknown,operationId=randomUUID())=>daemon.app.inject({method:'POST',url:'/v1/commands',headers:{authorization:`Bearer ${daemon.token}`},payload:{operationId,command}});
  try {
    const project=(await cmd({type:'project.add',path:repo})).json();
    const main=daemon.store.state().workspaces[0];
    assert.equal((await cmd({type:'workspace.delete',workspaceId:main.id})).json().error,'worktree_required');
    const ws=(await cmd({type:'workspace.create',projectId:project.id})).json();
    const remove={type:'workspace.delete',workspaceId:ws.id};
    await writeFile(join(ws.path,'hello.txt'),'unsaved changes');
    assert.equal((await cmd(remove)).json().error,'git_failed');
    assert.equal(await readFile(join(ws.path,'hello.txt'),'utf8'),'unsaved changes');
    await git(ws.path,['restore','hello.txt']);
    await writeFile(join(ws.path,'untracked.txt'),'keep');
    assert.equal((await cmd(remove)).json().error,'git_failed');
    await rm(join(ws.path,'untracked.txt'));
    await writeFile(join(ws.path,'.gitignore'),'.env\nlocal-data/\n');
    await git(ws.path,['add','.gitignore']);await git(ws.path,['commit','-m','ignore local data']);
    await writeFile(join(ws.path,'.env'),'LOCAL_SECRET=keep\n');
    assert.equal((await cmd(remove)).json().error,'workspace_ignored_files');
    assert.equal(await readFile(join(ws.path,'.env'),'utf8'),'LOCAL_SECRET=keep\n');
    assert.ok(daemon.store.state().workspaces.some(w=>w.id===ws.id));
    await rm(join(ws.path,'.env'));
    await mkdir(join(ws.path,'local-data'));
    await writeFile(join(ws.path,'local-data','database.sqlite'),'local database');
    assert.equal((await cmd(remove)).json().error,'workspace_ignored_files');
    assert.equal(await readFile(join(ws.path,'local-data','database.sqlite'),'utf8'),'local database');
    await rm(join(ws.path,'local-data'),{recursive:true});
    await git(repo,['worktree','lock',ws.path]);
    assert.equal((await cmd(remove)).json().error,'git_failed');
    await git(repo,['worktree','unlock',ws.path]);
    const terminal=(await cmd({type:'terminal.open',workspaceId:ws.id,provider:'shell'})).json();
    assert.ok(terminal.id);
    assert.equal((await cmd(remove)).json().error,'workspace_running');
    await cmd({type:'terminal.stop',terminalId:terminal.id});
    for(let i=0;i<100&&daemon.store.state().terminals.some(t=>t.id===terminal.id&&t.status==='running');i++)await new Promise(r=>setTimeout(r,50));
    assert.notEqual(daemon.store.state().terminals.find(t=>t.id===terminal.id)?.status,'running');
    const revision=daemon.store.state().revision,operation=randomUUID();
    assert.equal((await cmd(remove,operation)).statusCode,200);
    assert.equal((await cmd(remove,operation)).statusCode,200);
    await assert.rejects(stat(ws.path),{code:'ENOENT'});
    assert.ok(!(await git(repo,['worktree','list','--porcelain'])).includes(ws.path));
    assert.ok((await git(repo,['branch','--list',ws.branch])).includes(ws.branch));
    assert.equal(await readFile(join(repo,'hello.txt'),'utf8'),'hello\n');
    assert.ok(daemon.store.state().revision>revision);
    assert.equal(daemon.store.state().workspaces.length,1);
    assert.equal(daemon.store.state().terminals.length,0);
    assert.equal(daemon.store.output(terminal.id,0).chunks.length,0);
    await daemon.app.close();daemon=await createDaemon(data);
    assert.equal(daemon.store.state().workspaces.length,1);
    assert.equal((await cmd(remove)).json().error,'workspace_missing');
  } finally {await daemon.app.close();await rm(root,{recursive:true,force:true});}
});
