import {test} from 'node:test';
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {mkdtemp, mkdir, writeFile, readFile, rm} from 'node:fs/promises';
import {join, resolve} from 'node:path';
import {tmpdir} from 'node:os';
import {createServer} from 'node:net';
import {randomUUID} from 'node:crypto';
import {setTimeout as delay} from 'node:timers/promises';

const binary = process.env.NEURA_NATIVE_DAEMON;
for (const [failureMode, errorCode] of [['timeout', 'provider_probe_timeout'], ['failed', 'provider_probe_failed'], ['unsupported', 'claude_mcp_unsupported']])
test(`Claude ${failureMode} probe recovers on the next open without restarting the daemon`, {skip: !binary, timeout: 45000}, async () => {
  const root = await mkdtemp(join(tmpdir(), 'neura-probe-retry-'));
  const home = join(root, 'home'), data = join(root, 'data'), folder = join(root, 'folder');
  await mkdir(home); await mkdir(folder);
  const cli = join(root, 'claude');
  // Only synthetic CLI help/version and PTY output; no real provider or credentials.
  await writeFile(cli, `#!/bin/sh
case "$1" in
  --help)
    echo help >> "$HOME/probes"
    case "$(cat "$HOME/mode")" in
      timeout) exec /bin/sleep 30 ;;
      failed) exit 1 ;;
      unsupported) echo old-cli; exit 0 ;;
    esac
    echo '--mcp-config --append-system-prompt --settings'; exit 0 ;;
  --version) echo '2.1.322 fixture'; exit 0 ;;
esac
echo FIXTURE_READY
`, {mode: 0o700});
  await writeFile(join(home, 'mode'), failureMode);
  const listener = createServer();
  await new Promise(r => listener.listen(0, '127.0.0.1', r));
  const port = listener.address().port;
  await new Promise(r => listener.close(r));
  const child = spawn(resolve(binary), [], {cwd: root, env: {
    HOME: home, PATH: '/usr/bin:/bin', TMPDIR: root,
    NEURA_DEV_DATA_DIR: data, NEURA_DEV_PORT: String(port), NEURA_CLAUDE_PATH: cli,
  }, stdio: ['ignore', 'pipe', 'pipe']});
  let logs = '', token;
  for (const stream of [child.stdout, child.stderr]) stream.on('data', b => logs = (logs + b).slice(-8192));
  const ended = new Promise(r => child.once('exit', (code, signal) => r({code, signal})));
  const request = async (path, command) => {
    const response = await fetch(`http://127.0.0.1:${port}${path}`, {
      method: command ? 'POST' : 'GET',
      headers: {authorization: `Bearer ${token}`, 'content-type': 'application/json'},
      body: command ? JSON.stringify({operationId: randomUUID(), command}) : undefined,
      signal: AbortSignal.timeout(10000),
    });
    return {status: response.status, value: await response.json()};
  };
  const until = async check => {
    for (let i = 0; i < 200; i++) { if (await check()) return; await delay(25); }
    assert.fail(`fixture did not converge: ${logs}`);
  };
  try {
    await until(async () => {
      assert.equal(child.exitCode, null, logs);
      try { token = (await readFile(join(data, 'daemon-token'), 'utf8')).trim(); return (await request('/v1/state')).status === 200; } catch { return false; }
    });
    const project = await request('/v1/commands', {type: 'project.add', path: folder});
    assert.equal(project.status, 200);
    const state = (await request('/v1/state')).value;
    const workspace = state.workspaces.find(w => w.projectId === project.value.id);
    const open = () => request('/v1/commands', {type: 'terminal.open', workspaceId: workspace.id, provider: 'claude'});
    const result = await open();
    assert.equal(result.status, 409);
    assert.equal(result.value.error, errorCode);
    await writeFile(join(home, 'mode'), 'ready');
    const launched = await open();
    assert.equal(launched.status, 200, JSON.stringify(launched.value));
    await until(async () => {
      const output = (await request(`/v1/terminals/${launched.value.id}/output?after=0&chunksOnly=true`)).value;
      return output.chunks?.some(chunk => chunk.data.includes('FIXTURE_READY'));
    });
    assert.equal((await readFile(join(home, 'probes'), 'utf8')).trim().split('\n').length, 2);
    // Successful checks remain cached, preserving the normal launch fast path.
    await writeFile(join(home, 'mode'), 'failed');
    assert.equal((await open()).status, 200);
    assert.equal((await readFile(join(home, 'probes'), 'utf8')).trim().split('\n').length, 2);
  } finally {
    child.kill('SIGTERM');
    let timer;
    const result = await Promise.race([ended, new Promise(r => timer = setTimeout(() => r(null), 10000))]);
    clearTimeout(timer);
    if (!result) { child.kill('SIGKILL'); await ended; }
    await rm(root, {recursive: true, force: true});
    assert.equal(result?.code, 0, logs);
  }
});
