import { test } from 'node:test';
import assert from 'node:assert/strict';
import { publicAddress,fetchPublicSource } from '../packages/connectors/src/public-source.ts';
test('source importer refuses local, metadata, private, mapped and non-HTTPS targets',async()=>{
  for(const address of ['127.0.0.1','10.1.2.3','172.16.1.1','192.168.1.1','169.254.169.254','100.64.1.1','0.0.0.0','::1','::ffff:127.0.0.1'])assert.equal(publicAddress(address),false,address);
  assert.equal(publicAddress('93.184.216.34'),true);
  await assert.rejects(()=>fetchPublicSource('http://example.com'),/source_url_denied/);
  await assert.rejects(()=>fetchPublicSource('https://user:pass@example.com'),/source_url_denied/);
  await assert.rejects(()=>fetchPublicSource('https://127.0.0.1'),/source_private_address/);
});
