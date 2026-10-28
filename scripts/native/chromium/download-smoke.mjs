import {createServer} from 'node:http';
import {spawn, execFileSync} from 'node:child_process';
import {signApplication} from '../signing/sign.mjs';
import {readdirSync} from 'node:fs';
import {randomUUID} from 'node:crypto';
import {mkdtemp, readFile, readdir, cp, rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {resolve, join} from 'node:path';
import assert from 'node:assert/strict';
const data = await mkdtemp(join(tmpdir(), 'neura-download-smoke-'));
const bytes = Buffer.from(Array.from({length: 65536}, (_, i) => i % 251));
const server = createServer((request, response) => {
  if (request.url === '/favicon.ico') {response.writeHead(204); response.end(); return;}
  if (request.url.startsWith('/page/')) {
    const route = request.url.slice(6);
    response.setHeader('Content-Type', 'text/html');
    response.end(`<title>download-fixture-${route}</title><a href="/${route}" style="position:absolute;left:0;top:0;width:200px;height:60px">Download</a>`);
    return;
  }
  response.writeHead(200, {'Content-Type': 'application/octet-stream', 'Content-Disposition': 'attachment; filename="fixture.bin"', 'Content-Length': request.url === '/complete' ? bytes.length : 1000000000});
  if (request.url === '/complete') response.end(bytes);
  else if (request.url === '/failed') {
    // Fail only after CEF has opened a destination. A user may leave the native
    // save panel open indefinitely; network failure before selection tests a different path.
    const interval = setInterval(() => {
      if (!response.writableNeedDrain) response.write(bytes);
      try { if (readdirSync(join(data, 'downloads')).some(name => name !== 'complete.bin')) response.destroy(); } catch {}
    }, 100);
    response.on('close', () => clearInterval(interval));
  } else {
    const interval = setInterval(() => { if (!response.writableNeedDrain) response.write(bytes); }, 100);
    response.on('close', () => clearInterval(interval));
  }
});
try {
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const source = resolve(process.env.NEURA_APP_OUTPUT ?? 'apps/macos/dist/neuraOS.app');
  const app = join(data, 'neuraOS.app');
  await cp(source, app, {recursive: true, verbatimSymlinks: true});
  const plist = join(app, 'Contents/Info.plist');
  for (const [key, value] of [['CFBundleIdentifier', 'app.neuraos.download-smoke.' + randomUUID()], ['NeuraDataDirectory', data], ['NeuraEndpoint', 'http://127.0.0.1:1']]) {
    execFileSync('/usr/bin/plutil', ['-replace', key, '-string', value, plist]);
  }
  signApplication(app);
  execFileSync('/usr/bin/codesign', ['--verify', '--deep', '--strict', app]);
  const executable = join(app, 'Contents/MacOS/NeuraOS');
  const child = spawn(executable, ['--download-smoke', `http://127.0.0.1:${server.address().port}`, data], {stdio: 'inherit', detached: true});
  const timer = setTimeout(() => {try {process.kill(-child.pid, 'SIGKILL');} catch {}}, process.env.NEURA_DOWNLOAD_SMOKE_MANUAL ? 615000 : 75000);
  let code;
  try { code = await new Promise((resolve, reject) => {child.once('error', reject); child.once('exit', resolve);}); }
  finally { clearTimeout(timer); }
  const report = JSON.parse(await readFile(join(data, 'download-report.json'), 'utf8'));
  console.log(report);
  assert.equal(code, 0);
  assert.deepEqual(report.map(item => item.status), ['canceled', 'failed', 'canceled', 'complete']);
  assert.deepEqual(await readFile(join(data, 'downloads/complete.bin')), bytes);
  assert.deepEqual(await readdir(join(data, 'downloads')), ['complete.bin']);
  console.log(`Download save bytes, progress, cancel, network failure and destination dismissal passed. Evidence: ${data}`);
} finally {
  server.closeAllConnections();
  await new Promise(resolve => server.close(resolve));
  await rm(join(data, 'neuraOS.app'), {recursive: true, force: true});
  console.log(`Fixture evidence retained: ${data}`);
}
