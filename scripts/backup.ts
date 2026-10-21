import { readFile,writeFile,mkdir } from 'node:fs/promises';
import { resolve,join } from 'node:path';
import { randomUUID } from 'node:crypto';
import { LocalStore } from '../packages/sync/src/local-store.ts';
import { contentHash,ensure } from '../packages/policy/src/index.ts';
import type { State } from '../packages/contracts/src/index.ts';
const action=process.argv[2]??'export';const data=resolve(process.env.NEURA_DATA_DIR??'.data');const path=process.env.NEURA_DATABASE_PATH??join(data,'runner.sqlite');const store=new LocalStore(path,randomUUID());
try{
  if(action==='export'){
    const state=store.read();const snapshot={format:'neuraos-backup-v1',createdAt:new Date().toISOString(),state,hash:contentHash(JSON.stringify(state)),tombstones:state.tombstones};
    const dest=resolve(process.argv[3]??join(data,'backups',new Date().toISOString().replaceAll(':','-')+'.json'));await mkdir(join(dest,'..'),{recursive:true,mode:0o700});await writeFile(dest,JSON.stringify(snapshot),{mode:0o600,flag:'wx'});
    await writeFile(dest+'.deletions.json',JSON.stringify({workspaceId:state.workspaceId,exportedAt:new Date().toISOString(),tombstones:state.tombstones}),{mode:0o600,flag:'wx'});console.log(dest);
  }else if(action==='restore'){
    ensure(process.argv[3],'backup_path_required');const backup=JSON.parse(await readFile(resolve(process.argv[3]),'utf8')) as {format:string;state:State;hash:string;tombstones:State['tombstones']};
    ensure(backup.format==='neuraos-backup-v1'&&contentHash(JSON.stringify(backup.state))===backup.hash,'backup_integrity_failed');
    ensure(store.read().tasks.length===0&&store.read().memories.length===0,'restore_target_must_be_empty','既存データへ上書きせず、空の復元先を指定してください。');
    ensure(process.env.NEURA_DELETION_LEDGER,'latest_deletion_ledger_required','NEURA_DELETION_LEDGER に最新の削除台帳を指定してください。');
    const ledger=JSON.parse(await readFile(resolve(process.env.NEURA_DELETION_LEDGER),'utf8')) as {workspaceId:string;tombstones:State['tombstones']};ensure(ledger.workspaceId===backup.state.workspaceId,'deletion_ledger_workspace_mismatch');
    const restored=backup.state;restored.tombstones=[...restored.tombstones,...ledger.tombstones];for(const task of restored.tasks){for(const a of task.actions)if(a.status==='dispatching')a.status='unknown';if(['running','verifying','waiting_input','waiting_approval','queued'].includes(task.status)){task.status='blocked';task.reason='restored_requires_reconciliation';}for(const r of task.runs)r.leaseUntil=new Date(0).toISOString();}
    for(const d of restored.devices)d.status='revoked'; // Device enrollment must be explicit after restoration.
    store.transaction(()=>store.write(restored));const check=store.read();for(const t of check.tasks)for(const a of t.artifacts)ensure(contentHash(a.content)===a.hash,'artifact_corrupt');console.log('Restored and verified. Devices revoked; runs require reconciliation.');
  }else throw new Error('Usage: pnpm backup [export|restore] [path]');
}finally{store.close();}
