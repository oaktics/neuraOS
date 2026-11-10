// neuraOS update feed. Serves the Sparkle appcast and signed release
// archives from R2, so updates work even when the GitHub repository is
// private. Integrity does not depend on this Worker: Sparkle verifies the
// EdDSA signature in the appcast and the Developer ID of the new app.
//
// R2 layout (written by .github/workflows/release.yml):
//   appcast.xml
//   releases/neuraOS-<build>-darwin-arm64.zip

const ARCHIVE = /^\/releases\/(neuraOS-[0-9]+-darwin-arm64\.zip)$/;

function headers(object, extra) {
  const result = new Headers(extra);
  object.writeHttpMetadata(result);
  result.set('etag', object.httpEtag);
  return result;
}

async function serve(request, bucket, key, cacheControl) {
  // R2 evaluates Range and If-None-Match/If-Match headers itself.
  const object = await bucket.get(key, {range: request.headers, onlyIf: request.headers});
  if (object === null) return new Response('Not found\n', {status: 404});
  const result = headers(object, {'cache-control': cacheControl, 'accept-ranges': 'bytes'});
  // `body` is absent when a precondition failed (e.g. If-None-Match matched).
  if (!('body' in object)) return new Response(null, {status: 304, headers: result});
  let status = 200;
  if (object.range && request.headers.has('range')) {
    const range = object.range;
    const offset = 'suffix' in range ? object.size - range.suffix : range.offset ?? 0;
    const length = 'suffix' in range ? range.suffix : range.length ?? object.size - offset;
    result.set('content-range', `bytes ${offset}-${offset + length - 1}/${object.size}`);
    result.set('content-length', String(length));
    status = 206;
  } else {
    result.set('content-length', String(object.size));
  }
  return new Response(request.method === 'HEAD' ? null : object.body, {status, headers: result});
}

export default {
  async fetch(request, env) {
    if (request.method !== 'GET' && request.method !== 'HEAD')
      return new Response('Method not allowed\n', {status: 405, headers: {allow: 'GET, HEAD'}});
    const {pathname} = new URL(request.url);
    if (pathname === '/appcast.xml')
      // Revalidate every time so a new release is seen on the next check.
      return serve(request, env.UPDATES, 'appcast.xml', 'no-cache');
    const archive = ARCHIVE.exec(pathname);
    // Archive names contain the build number and are never overwritten.
    if (archive) return serve(request, env.UPDATES, `releases/${archive[1]}`, 'public, max-age=31536000, immutable');
    if (pathname === '/') return new Response('neuraOS updates\n', {headers: {'content-type': 'text/plain; charset=utf-8'}});
    return new Response('Not found\n', {status: 404});
  },
};
