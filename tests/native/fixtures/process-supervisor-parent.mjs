// Synthetic daemon protocol fixture, never used by the product.
import {spawn} from 'node:child_process';
import {createInterface} from 'node:readline';
import {writeFile} from 'node:fs/promises';
import {randomUUID} from 'node:crypto';
const [binary,fixture,dir,countText,mode]=process.argv.slice(2),count=Number(countText);
const helper=spawn(binary,['process-supervisor'],{stdio:['pipe','pipe','inherit']});
const pending=new Map();let next=0;
createInterface({input:helper.stdout}).on('line',line=>{const value=JSON.parse(line);pending.get(value.id)?.(value);pending.delete(value.id);});
const request=async value=>{const id=String(++next);const response=new Promise(resolve=>pending.set(id,resolve));helper.stdin.write(JSON.stringify({...value,id})+'\n');const result=await response;if(!result.ok)throw Error(result.error);};
await writeFile(dir+'/helper',String(helper.pid));
const tokens=[];
for(let i=0;i<count;i++){
 const token=randomUUID();await request({op:'reserve',token});tokens.push(token);
 const child=spawn(fixture,[dir+'/pids-'+i,dir+'/writes-'+i,'detached'],{env:{...process.env,NEURA_PROCESS_OWNER:token},detached:true,stdio:'ignore'});
 if(mode!=='before-attach')await request({op:'attach',token,pid:child.pid});
}
console.log('ready');
process.stdin.once('data',async()=>{
 if(mode==='timeout'){await Promise.all(tokens.map(token=>request({op:'stop',token})));helper.stdin.end();}
 else helper.stdin.end();
});
helper.on('exit',code=>process.exit(code??1));
