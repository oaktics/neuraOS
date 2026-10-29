// Isolated disk-backed burst benchmark; never opens the application database.
import {mkdtempSync,rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {Store} from '../../apps/daemon/src/store.ts';
const results=[];
for(const mode of ['unbatched','batched']){
  const durations=[];
  for(let run=0;run<5;run++){
    const dir=mkdtempSync(join(tmpdir(),'neura-output-bench-'));
    const store=new Store(join(dir,'bench.sqlite'));
    try{
      const start=performance.now();
      for(let i=0;i<2000;i++){
        const id=`terminal-${i%10}`,data=`\x1b[32moutput ${i}\x1b[0m\r\n`;
        if(mode==='unbatched')store.db.prepare('INSERT INTO output(terminalId,data) VALUES(?,?)').run(id,data);
        else store.append(id,data);
      }
      store.flushOutput();durations.push(performance.now()-start);
      if(store.db.prepare('SELECT count(*) AS n FROM output').get().n!==2000)throw new Error('Incomplete output');
    }finally{store.close();rmSync(dir,{recursive:true,force:true});}
  }
  results.push({mode,terminals:10,chunks:2000,durationsMs:durations,medianMs:[...durations].sort((a,b)=>a-b)[2]});
}
console.log(JSON.stringify(results,null,2));
