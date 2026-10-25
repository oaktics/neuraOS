import test from 'node:test';
import assert from 'node:assert/strict';
import {summarize} from '../../scripts/reliability/summary.mjs';

test('weekly report deduplicates overlapping exports and daemon events, separates builds and incomplete actions', () => {
  const now=Date.parse('2026-10-26T00:00:00Z');
  const event=(event,operationId,build='21')=>({time:'2026-10-25T00:00:00Z',event,operationId,build,operation:'workspace.create',session:'a'});
  const log=[event('session.start'),event('operation.start','ok'),event('operation.success','ok'),event('operation.start','bad'),event('operation.failure','bad'),event('operation.start','pending'),event('operation.slow','pending'),event('operation.failure','no-start'),event('session.start',undefined,'22')].map(JSON.stringify).join('\n');
  const report={logs:{'app.jsonl':log+'\npartial','daemon.jsonl':log}};
  const result=summarize([report,report],now),row=result.rows.find(r=>r.build==='21');
  assert.equal(row.operationsStarted,3);assert.equal(row.operationsFinished,2);
  assert.equal(row.failureRate,0.5);assert.equal(row.slowOperations,1);
  assert.equal(result.rows.length,2);assert.equal(result.rows.find(r=>r.build==='22').failureRate,null);
});
