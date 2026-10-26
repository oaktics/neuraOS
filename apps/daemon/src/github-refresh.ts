// Share concurrent reads across views/worktrees, with bounded retention and
// failure cooldown. Manual refresh bypasses freshness, never a failure cooldown.
export class GitHubRefreshCache<T> {
  private entries=new Map<string,{result:Promise<T>;expires:number;pending:boolean;failed:boolean}>();
  private active=0;
  private waiting:Array<()=>void>=[];
  constructor(private ttl:(value:T)=>number,private now=Date.now){}
  read(key:string,fetch:()=>Promise<T>,force=false):Promise<T>{
    const old=this.entries.get(key);
    if(old&&(old.pending||old.expires>this.now()&&(!force||old.failed)))return old.result;
    const entry:{result:Promise<T>;expires:number;pending:boolean;failed:boolean}={result:Promise.resolve(null as T),expires:Infinity,pending:true,failed:false};
    entry.result=this.limited(fetch).then(value=>{
      entry.expires=this.now()+this.ttl(value);return value;
    },error=>{
      entry.failed=true;entry.expires=this.now()+60000;throw error;
    }).finally(()=>{entry.pending=false;this.trim();});
    this.entries.set(key,entry);
    this.trim();return entry.result;
  }
  private async limited(fetch:()=>Promise<T>):Promise<T>{
    if(this.active>=4)await new Promise<void>(resolve=>this.waiting.push(resolve));
    else this.active++;
    try{return await fetch();}
    finally{const next=this.waiting.shift();if(next)next();else this.active--;}
  }
  invalidate(prefix:string){for(const key of this.entries.keys())if(key.startsWith(prefix))this.entries.delete(key);}
  private trim(){for(const [key,entry] of this.entries){if(this.entries.size<=256)break;if(!entry.pending)this.entries.delete(key);}}
}
