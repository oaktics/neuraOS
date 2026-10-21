import type { Memory, State, Task } from '../../contracts/src/index.ts';
export function resolveMemories(state:State,task:Task,now:Date):Memory[] {
  const rank={task:0,project:1,workspace:2,'user-global':3};
  return state.memories.filter(m=>m.state==='active' && !state.tombstones.some(t=>t.id===m.id) && (!m.expiresAt||Date.parse(m.expiresAt)>now.getTime()) && m.classification!=='local-only' && (m.classification!=='restricted'||task.classification==='restricted') && (m.scope==='task'?m.scopeId===task.id:m.scope==='project'?m.scopeId===task.projectId:m.scopeId===null))
    .sort((a,b)=>rank[a.scope]-rank[b.scope] || Number(b.explicit)-Number(a.explicit) || b.updatedAt.localeCompare(a.updatedAt));
}
export function memoryContext(memories:Memory[]) {return memories.map(m=>({id:m.id,version:m.version,kind:m.kind,scope:m.scope,content:m.content,evidence:m.evidence}));}
