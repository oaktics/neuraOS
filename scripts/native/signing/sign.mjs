import {execFileSync} from 'node:child_process';
import {join} from 'node:path';
import {openSync, readSync, closeSync, readdirSync} from 'node:fs';

export function selectIdentity(env = process.env, identities) {
  if (env.NEURA_SIGN_IDENTITY) {
    if (env.NEURA_REQUIRE_DEVELOPER_ID === '1' && !env.NEURA_SIGN_IDENTITY.startsWith('Developer ID Application:'))
      throw new Error('Release requires a Developer ID Application identity');
    return env.NEURA_SIGN_IDENTITY;
  }
  const available = identities ?? execFileSync('security', ['find-identity', '-v', '-p', 'codesigning'], {encoding: 'utf8'});
  const names = [...new Set([...available.matchAll(/"(Developer ID Application:[^"\n]+)"/g)].map(match => match[1]))];
  if (names.length !== 1) throw new Error('Set NEURA_SIGN_IDENTITY to your Developer ID Application certificate name. For disposable tests only, set NEURA_SIGN_IDENTITY=-.');
  return names[0];
}

// Inspect file headers, including universal binaries, rather than a filename allowlist.
export function isMachO(file) {
  const fd = openSync(file, 'r');
  try {
    const magic = Buffer.alloc(4);
    return readSync(fd, magic, 0, 4, 0) === 4 &&
      ['feedface', 'cefaedfe', 'feedfacf', 'cffaedfe', 'cafebabe', 'bebafeca', 'cafebabf', 'bfbafeca'].includes(magic.toString('hex'));
  } finally {closeSync(fd);}
}

export function signCertifiedTree(app, identity, run = execFileSync) {
  function sign(path, entitlement = 'empty') {
    run('codesign', ['--force', '--options', 'runtime', '--timestamp', '--sign', identity,
      ...(process.env.NEURA_SIGN_KEYCHAIN ? ['--keychain', process.env.NEURA_SIGN_KEYCHAIN] : []),
      '--entitlements', join(import.meta.dirname, `${entitlement}.entitlements.plist`), path], {stdio: 'inherit'});
  }
  function walk(path) {
    for (const entry of readdirSync(path, {withFileTypes: true})) {
      const file = join(path, entry.name);
      if (entry.isDirectory()) {
        walk(file);
        if (entry.name.endsWith('.framework')) sign(file);
        else if (entry.name.endsWith('.app')) sign(file, / \((Renderer|GPU)\)\.app$/.test(entry.name) ? 'jit' : 'empty');
      } else if (entry.isFile() && isMachO(file)) {
        sign(file, ['node', 'claude'].includes(entry.name) ? 'jit' : 'empty');
      }
      // Never traverse symlinks: framework aliases and pnpm links share targets.
    }
  }
  walk(app);
  sign(app, 'certified-client');
  run('codesign', ['--verify', '--deep', '--strict', app], {stdio: 'inherit'});
}

export function signApplication(app, identity = selectIdentity()) {
  if (identity !== '-') return signCertifiedTree(app, identity);
  // Sign nested CEF/runtime components first. Then explicitly harden the only
  // privileged IPC peers; a later --deep signing pass must not undo these flags.
  execFileSync('codesign', ['--force', '--deep', '--sign', '-', app], {stdio: 'inherit'});
  execFileSync('codesign', ['--force', '--options', 'runtime', '--sign', '-', join(app, 'Contents/MacOS/NeuraSleepService')], {stdio: 'inherit'});
  execFileSync('codesign', ['--force', '--options', 'runtime', '--entitlements', join(import.meta.dirname, 'client.entitlements.plist'), '--sign', '-', app], {stdio: 'inherit'});
}
