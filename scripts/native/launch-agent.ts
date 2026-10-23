import {execFile} from 'node:child_process';
import {promisify} from 'node:util';
const exec = promisify(execFile);

// launchd can still be removing a job after bootout returns. Retry only its
// transient bootstrap EIO; permission/plist errors must remain visible.
export async function replaceLaunchAgent(domain: string, id: string, plist: string, {
  execute = async (args: string[]) => exec('/bin/launchctl', args, {timeout: 5000, killSignal: 'SIGKILL'}),
  pause = (ms: number) => new Promise<void>(resolve => setTimeout(resolve, ms)),
} = {}) {
  try {await execute(['bootout', `${domain}/${id}`]);}
  catch (error) {if ((error as {code?: number}).code !== 3) throw error;}
  for (let attempt = 0; ; attempt++) {
    try {await execute(['bootstrap', domain, plist]); return;}
    catch (error) {
      if ((error as {code?: number}).code !== 5 || attempt >= 19) throw error;
      await pause(500);
    }
  }
}
