// HTTP completion and output notifications do not fence state invalidations.
// Observe the already-ready stream until every target has a stateful change.
export function waitForStateInvalidations({ws,events},terminalIds,after=0,timeoutMs=15000) {
 const ids=[...terminalIds];
 return new Promise((resolve,reject)=>{
  let timer;
  const seen=()=>new Set(events.slice(after).filter(e=>e.type==='changed'&&e.state===true).flatMap(e=>e.terminals??[]));
  const cleanup=()=>{clearTimeout(timer);ws.off('message',check);ws.off('close',closed);ws.off('error',failed);};
  const check=()=>{const notified=seen();if(ids.every(id=>notified.has(id))){cleanup();resolve();}};
  const failed=()=>{cleanup();reject(Error('stream failed before stateful exit invalidations'));};
  const closed=()=>{cleanup();reject(Error('stream closed before stateful exit invalidations'));};
  // The fixture's collector is installed before this listener and records each
  // message synchronously. Listen before inspecting to avoid a check/listen gap.
  ws.on('message',check);ws.once('close',closed);ws.once('error',failed);
  timer=setTimeout(()=>{const notified=seen();cleanup();reject(Error(`deadline: stateful exit invalidations missing ${ids.filter(id=>!notified.has(id)).length}/${ids.length}`));},timeoutMs);
  check();
 });
}
