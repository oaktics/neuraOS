import {execFileSync} from 'node:child_process';
import {mkdir, mkdtemp, rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join, resolve} from 'node:path';

const assets = resolve(import.meta.dirname, '../../apps/macos/Assets');
const temporary = await mkdtemp(join(tmpdir(), 'neuraos-icon-'));
const iconset = join(temporary, 'AppIcon.iconset');
try {
  await mkdir(iconset);
  for (const size of [16, 32, 128, 256, 512]) {
    for (const scale of [1, 2]) {
      execFileSync('/usr/bin/sips', ['-z', String(size * scale), String(size * scale),
        join(assets, 'AppIcon.png'), '--out',
        join(iconset, `icon_${size}x${size}${scale === 2 ? '@2x' : ''}.png`)], {stdio: 'pipe'});
    }
  }
  execFileSync('/usr/bin/iconutil', ['-c', 'icns', iconset, '-o', join(assets, 'AppIcon.icns')], {stdio: 'inherit'});
} finally {
  await rm(temporary, {recursive: true, force: true});
}
