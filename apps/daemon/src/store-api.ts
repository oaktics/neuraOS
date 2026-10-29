import type {Store as LegacyStore} from './store.ts';
/** Adapter-facing async API. LegacyStore is retained only for old unit fixtures/benchmarks. */
type Awaitable<T> = T | Promise<T>;
export interface StoreAPI {
  list<T>(table:'projects'|'workspaces'|'terminals'|'agents'):Awaitable<T[]>;
  get<T>(table:'projects'|'workspaces'|'terminals'|'agents',id:string):Awaitable<T|undefined>;
  put<T extends {id:string}>(table:'projects'|'workspaces'|'terminals'|'agents',value:T,notification?:Parameters<LegacyStore['put']>[2]):Awaitable<void>;
  putProjectWorkspace: (...args:Parameters<LegacyStore['putProjectWorkspace']>)=>Awaitable<void>;
  deleteWorkspace:(id:string)=>Awaitable<void>;
  removeProject:(id:string)=>Awaitable<void>;
  state:()=>Awaitable<ReturnType<LegacyStore['state']>>;
  append:(id:string,data:string)=>Awaitable<void>;
  resize:(id:string,cols:number,rows:number)=>Awaitable<void>;
  output:(id:string,after:number)=>Awaitable<ReturnType<LegacyStore['output']>>;
  notifications:(after:number)=>Awaitable<ReturnType<LegacyStore['notifications']>>;
  close:()=>Awaitable<void>;
}
