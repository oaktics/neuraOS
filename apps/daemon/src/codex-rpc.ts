import WebSocket from 'ws';
import {spawn,execFile,type ChildProcessWithoutNullStreams} from 'node:child_process';
import {promisify} from 'node:util';
import {parseProcessTable,processGroupAlive} from './terminals.ts';
import {mkdtemp,access,rm} from 'node:fs/promises';
import {join} from 'node:path';
import {Fault} from './contracts.ts';

export type RPCEvent={method:string;params?:any;id?:number|string};
/** A private server and a control client. The TUI is a second client of the same server. */
export class CodexRPC {
  private sequence=0;
  private pending=new Map<number,{resolve:(value:any)=>void;reject:(error:Error)=>void;timer:NodeJS.Timeout}>();
  private closed=false;
  private stopping?:Promise<void>;
  private groups=new Set<number>();
  private constructor(readonly endpoint:string,readonly pid:number,private directory:string,private server:ChildProcessWithoutNullStreams,private socket:WebSocket,private event:(event:RPCEvent)=>void){
    socket.on('message',raw=>{
      try {
        const message=JSON.parse(raw.toString());
        if(message.method){this.event(message);return;}
        const pending=this.pending.get(message.id);
        if(pending){this.pending.delete(message.id);clearTimeout(pending.timer);message.error?pending.reject(new Fault('codex_rpc_error',String(message.error.message).slice(0,1000),409)):pending.resolve(message.result);}
      }catch{this.fail();}
    });
    socket.on('error',()=>this.fail());socket.on('close',()=>this.fail());server.on('exit',()=>this.fail());
    server.stderr.resume();server.stdout.resume();
  }
  static async start(program:string,env:Record<string,string>,args:string[],event:(event:RPCEvent)=>void){
    const directory=await mkdtemp('/tmp/neura-codex-'),socket=join(directory,'server.sock');
    const server=spawn(program,['app-server','--listen',`unix://${socket}`,...args],{env,detached:true,stdio:'pipe'});
    let startupError:Error|undefined;server.on('error',e=>{startupError=e;});server.stderr.resume();server.stdout.resume();
    try {
      let ready=false;
      for(let attempt=0;attempt<200;attempt++){
        if(startupError||server.exitCode!==null)throw new Error('Codex App Server could not start');
        try{await access(socket);ready=true;break;}catch{}
        await new Promise(r=>setTimeout(r,25));
      }
      if(!ready||!server.pid)throw new Error('Codex App Server startup timed out');
      const connection=new WebSocket(`ws+unix:${socket}:/`,{maxPayload:16*1024*1024,handshakeTimeout:5000});
      await new Promise<void>((resolve,reject)=>{connection.once('open',resolve);connection.once('error',reject);});
      const rpc=new CodexRPC(`unix://${socket}`,server.pid,directory,server,connection,event);
      try{await rpc.call('initialize',{clientInfo:{name:'neuraos_supervision',title:'neuraOS',version:'0.2.0'}});rpc.notify('initialized',{});return rpc;}
      catch(e){await rpc.close();throw e;}
    }catch(e){if(server.pid)try{process.kill(-server.pid,'SIGKILL');}catch{}await rm(directory,{recursive:true,force:true});throw e;}
  }
  call(method:string,params:unknown={}):Promise<any>{
    if(this.closed)return Promise.reject(new Fault('codex_disconnected','Codexとの接続が切れています。',409));
    const id=++this.sequence;
    return new Promise((resolve,reject)=>{
      const timer=setTimeout(()=>{this.pending.delete(id);reject(new Fault('codex_timeout','Codexの応答を確認できません。再送前に会話を確認してください。',504));},12000);
      this.pending.set(id,{resolve,reject,timer});this.socket.send(JSON.stringify({id,method,params}));
    });
  }
  notify(method:string,params:unknown){if(!this.closed)this.socket.send(JSON.stringify({method,params}));}
  reply(id:number|string,result:unknown){if(!this.closed)this.socket.send(JSON.stringify({id,result}));}
  private fail(){if(this.closed)return;this.closed=true;for(const p of this.pending.values()){clearTimeout(p.timer);p.reject(new Fault('codex_disconnected','Codexとの接続が切れています。',409));}this.pending.clear();this.event({method:'neura/disconnected'});}
  signal(signal:NodeJS.Signals){if(this.pid>0)try{process.kill(-this.pid,signal);}catch(e){if((e as NodeJS.ErrnoException).code!=='ESRCH')throw e;}}
  close(){
    if(this.stopping)return this.stopping;
    const result=this.stopTree();this.stopping=result;
    void result.catch(()=>{this.stopping=undefined;});return result;
  }
  private async stopTree(){
    this.fail();this.socket.terminate();this.groups.add(this.pid);
    const started=Date.now();
    do {
      const {stdout}=await promisify(execFile)('/bin/ps',['-axo','pid=,ppid=,pgid='],{timeout:3000,maxBuffer:8*1024*1024});
      const rows=parseProcessTable(stdout),owned=new Set(rows.filter(r=>this.groups.has(r.group)).map(r=>r.pid));
      let changed=true;while(changed){changed=false;for(const row of rows)if(owned.has(row.parent)&&!owned.has(row.pid)){owned.add(row.pid);if(row.group>0)this.groups.add(row.group);changed=true;}}
      const alive=[...this.groups].filter(group=>processGroupAlive(group));
      if(!alive.length){await rm(this.directory,{recursive:true,force:true});return;}
      for(const group of alive)try{process.kill(-group,Date.now()-started<1500?'SIGTERM':'SIGKILL');}catch(e){if((e as NodeJS.ErrnoException).code!=='ESRCH')throw e;}
      if(Date.now()-started>5000)throw new Fault('codex_stop_timeout','Codexの子プロセスの停止を確認できません。再度停止してください。',409);
      await new Promise(r=>setTimeout(r,50));
    }while(true);
  }
}
