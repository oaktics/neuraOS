import {access, stat} from 'node:fs/promises';
import {constants} from 'node:fs';
import {execFileSync} from 'node:child_process';
import {resolve} from 'node:path';

// Match BrowserFixture's exact string comparison: do not canonicalize /tmp aliases.
export function validateBrowserConfiguration(plist, {data, endpoint}) {
  const checks = [
    ['CFBundleIdentifier', 'com.neuraos.browser-smoke.*', v => typeof v === 'string' && v.startsWith('com.neuraos.browser-smoke.')],
    ['NeuraDataDirectory', data, v => v === data],
    ['NeuraEndpoint', endpoint, v => v === endpoint],
  ];
  for (const [field, expected, valid] of checks) {
    if (!valid(plist[field])) {
      // Print only allowlisted configuration shapes; never URL credentials/query or user paths.
      const value = plist[field];
      const safe = typeof value === 'string' && (field === 'CFBundleIdentifier' ? /^[a-zA-Z0-9.-]{1,180}$/.test(value) :
        field === 'NeuraDataDirectory' ? /^\/(?:private\/)?tmp\/neura-browser[\w.-]+$/.test(value) : /^http:\/\/127\.0\.0\.1:\d+$/.test(value));
      throw Error(`Browser preflight ${field}: expected=${expected}; actual=${safe ? value : value == null ? '<missing>' : '<redacted non-fixture value>'}`);
    }
  }
}
export async function browserPreflight(app, options) {
  const executable = resolve(app, 'Contents/MacOS/NeuraOS');
  try {await access(executable, constants.X_OK); if (!(await stat(executable)).isFile()) throw Error();}
  catch {throw Error('Browser preflight executable: candidate missing or not executable');}
  let plist;
  try {plist = JSON.parse(execFileSync('/usr/bin/plutil', ['-convert', 'json', '-o', '-', resolve(app, 'Contents/Info.plist')], {encoding:'utf8', stdio:['ignore','pipe','pipe']}));}
  catch {throw Error('Browser preflight Info.plist: missing or invalid');}
  validateBrowserConfiguration(plist, options);
  return executable;
}

export function monitorBrowserChild(child) {
  let failure;
  let rejectExit;
  const exited = new Promise((_, reject) => {rejectExit = reject;});
  // A handler is attached immediately, even before the first readiness await.
  exited.catch(() => {});
  child.once('error', () => {failure = Error('Browser app failed to spawn'); rejectExit(failure);});
  child.once('exit', (code, signal) => {failure = Error(`Browser app exited early: code=${code} signal=${signal}`); rejectExit(failure);});
  return {check() {if (failure) throw failure;}, race(promise) {return failure ? Promise.reject(failure) : Promise.race([promise, exited]);}};
}
