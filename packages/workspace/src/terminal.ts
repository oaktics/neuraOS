import * as pty from 'node-pty';
import {randomUUID} from 'node:crypto';
import {ensure} from '../../policy/src/index.ts';
export class Terminals {
 private sessions=new Map<string,{id:string;projectId:string;taskId?:string;pty:pty.IPty;output:string;offset:number;exited:boolean}>();
 open(projectId:string,taskId:string|undefined,cwd:string,program?:{file:string;args:string[]}){const previous=[...this.sessions.values()].find(s=>s.projectId===projectId&&s.taskId===taskId&&!s.exited);if(previous)return {id:previous.id};ensure(this.sessions.size<24,'terminal_limit');const id=randomUUID();const env:Record<string,string>={TERM:'xterm-256color',LANG:process.env.LANG??'en_US.UTF-8',HOME:process.env.HOME??'',USER:process.env.USER??'',SHELL:process.platform==='win32'?'powershell.exe':'/bin/zsh',PATH:[(process.env.HOME??'')+'/.local/bin','/opt/homebrew/bin','/usr/local/bin',process.env.PATH??'/usr/bin:/bin'].join(':')};const proc=pty.spawn(program?.file??env.SHELL,program?.args??(process.platform==='win32'?[]:['-l']),{name:'xterm-256color',cwd,env,cols:100,rows:24});const session={id,projectId,taskId,pty:proc,output:'',offset:0,exited:false};proc.onData(data=>{session.output+=data;if(session.output.length>1000000){const removed=session.output.length-1000000;session.output=session.output.slice(removed);session.offset+=removed;}});proc.onExit(()=>{session.exited=true;});this.sessions.set(id,session);return {id};}
 get(id:string,projectId:string){const s=this.sessions.get(id);ensure(s&&s.projectId===projectId,'terminal_missing');return s;}
 poll(id:string,projectId:string,offset:number){const s=this.get(id,projectId);return {data:s.output.slice(Math.max(0,offset-s.offset)),offset:s.offset+s.output.length,reset:offset<s.offset,exited:s.exited};}
 write(id:string,projectId:string,data:string){const s=this.get(id,projectId);ensure(!s.exited,'terminal_exited');s.pty.write(data);}
 resize(id:string,projectId:string,cols:number,rows:number){this.get(id,projectId).pty.resize(cols,rows);}
 close(id:string,projectId:string){const s=this.get(id,projectId);s.pty.kill();this.sessions.delete(id);}
 activeId(projectId:string,taskId:string){return [...this.sessions.values()].find(s=>s.projectId===projectId&&s.taskId===taskId&&!s.exited)?.id??null;}
 busy(taskId:string){return [...this.sessions.values()].some(s=>s.taskId===taskId&&!s.exited);}
 shutdown(){for(const s of this.sessions.values())s.pty.kill();this.sessions.clear();}
}
