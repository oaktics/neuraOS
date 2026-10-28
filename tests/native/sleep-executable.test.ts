import {test} from 'node:test';
import assert from 'node:assert/strict';
import {execFile, spawnSync} from 'node:child_process';
import {promisify} from 'node:util';
import {mkdtemp, rm, writeFile, realpath} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join, resolve} from 'node:path';

const exec = promisify(execFile);
test('sleep helper locates its executable with a relative launchd argv0', {skip: process.platform !== 'darwin', timeout: 210000}, async () => {
  const dir = await mkdtemp(join(tmpdir(), 'neura-sleep-path-'));
  try {
    const binary = join(dir, 'probe');
    const source = join(dir, 'main.swift');
    await writeFile(source, 'import Foundation\nprint(CommandLine.arguments[0])\nprint(try SleepService.executableURL().path)\n');
    await exec('xcrun', ['swiftc', '-swift-version', '5',
      resolve('apps/macos/Sources/SleepControl/SleepLease.swift'),
      resolve('apps/macos/Sources/SleepControl/SleepSession.swift'),
      resolve('apps/macos/Sources/SleepControl/SleepService.swift'), source, '-o', binary], {timeout: 180000});
    for (const argv0 of ['Contents/MacOS/NeuraSleepService', 'NeuraSleepService', binary]) {
      const result = spawnSync(binary, [], {argv0, cwd: '/', timeout: 10000, encoding: 'utf8'});
      assert.equal(result.status, 0, result.stderr || String(result.error));
      const [actualArgv0, executablePath] = result.stdout.trim().split('\n');
      assert.equal(actualArgv0, argv0);
      assert.equal(await realpath(executablePath), await realpath(binary));
    }
  } finally {await rm(dir, {recursive: true, force: true});}
});
