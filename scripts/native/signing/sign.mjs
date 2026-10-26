import {execFileSync} from 'node:child_process';
import {join} from 'node:path';

export function signApplication(app) {
  // Sign nested CEF/runtime components first. Then explicitly harden the only
  // privileged IPC peers; a later --deep signing pass must not undo these flags.
  execFileSync('codesign', ['--force', '--deep', '--sign', '-', app], {stdio: 'inherit'});
  execFileSync('codesign', ['--force', '--options', 'runtime', '--sign', '-', join(app, 'Contents/MacOS/NeuraSleepService')], {stdio: 'inherit'});
  execFileSync('codesign', ['--force', '--options', 'runtime', '--entitlements', join(import.meta.dirname, 'client.entitlements.plist'), '--sign', '-', app], {stdio: 'inherit'});
}
