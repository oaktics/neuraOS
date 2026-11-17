export function appInfoPlist(options: {
  bundleId: string;
  version: string;
  build: string;
  dataDirectory?: string;
  port?: string;
  sparkleKeys?: string;
}): string;
