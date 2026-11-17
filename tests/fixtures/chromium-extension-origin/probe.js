// The harness supplies a disposable loopback endpoint. No external services,
// credentials, native messaging, or altered Origin headers are involved.
globalThis.probeOrigin = async (endpoint, method) => {
  const url = new URL(endpoint);
  if (url.protocol !== 'http:' || !['127.0.0.1', 'localhost'].includes(url.hostname)) {
    throw new Error('Origin probe only accepts loopback HTTP');
  }
  const response = await fetch(url, {
    method,
    headers: {'X-Probe': 'origin-fixture'},
    signal: AbortSignal.timeout(10000),
  });
  if (!response.ok) throw new Error(`Echo HTTP ${response.status}`);
  return response.json();
};
