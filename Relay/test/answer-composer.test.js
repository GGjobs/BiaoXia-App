import test from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { handleRequest } from '../src/index.js';
import { composeAnswerWithFallback, validateCompositionRequest, validateCompositionOutput } from '../src/answer-composer.js';
const body = () => ({ schemaVersion: 1, requestId: randomUUID(), fieldLabel: '项目简介', instructions: '简短介绍', sources: [{ id: 'source-1', text: '虚构资料：负责界面原型' }] });
const output = { answer: '负责界面原型。', sourceIDs: ['source-1'], missingInformation: [] };
test('composition accepts only selected snippets and validates provenance', () => {
  const request = body(); validateCompositionRequest(request);
  assert.throws(() => validateCompositionRequest({ ...request, rawOCR: 'private' }));
  assert.throws(() => validateCompositionOutput({ ...output, sourceIDs: ['source-2'] }, request));
  assert.throws(() => validateCompositionOutput({ ...output, sourceIDs: [] }, request));
  assert.throws(() => validateCompositionOutput({ ...output, answer: 'a'.repeat(9000) }, request));
  assert.deepEqual(validateCompositionOutput({ answer: null, sourceIDs: [], missingInformation: ['缺少具体职责'] }, request).answer, null);
});
test('composition retries malformed output at most twice and never adds sources', async () => {
  let calls = 0;
  await assert.rejects(composeAnswerWithFallback(body(), { callModel: async () => { calls++; return { content: JSON.stringify({ ...output, sourceIDs: ['invented'] }) }; } }));
  assert.equal(calls, 2);
});
test('HTTP composition keeps selected contents out of logs and public envelope', async () => {
  const request = body(), logs = [];
  const response = await handleRequest(new Request('https://relay.test/v1/compose-answer', { method: 'POST', headers: { authorization: 'Bearer fixture' }, body: JSON.stringify(request) }), {
    env: { RELAY_CLIENT_TOKEN: 'fixture' }, logger: { info: x => logs.push(x), error: x => logs.push(x) },
    callModel: async ({ messages }) => { assert.ok(messages[1].content.includes(request.sources[0].text)); return { content: JSON.stringify(output) }; },
  });
  assert.equal(response.status, 200);
  const result = await response.json(); assert.equal(result.answer, output.answer);
  assert.deepEqual(Object.keys(result).sort(), ['answer', 'missingInformation', 'requestId', 'schemaVersion', 'sourceIDs'].sort());
  assert.ok(!logs.join('').includes(request.sources[0].text)); assert.ok(!logs.join('').includes(output.answer));
});
test('v2 allows extended meanings while v1 contract rejects them', async () => {
  const request = { schemaVersion: 2, requestId: randomUUID(), fields: [{ id: 'field-1', label: '证书', kind: 'multilineText', options: [] }] };
  const options = { env: { RELAY_CLIENT_TOKEN: 'fixture' }, logger: { info() {}, error() {} }, callModel: async () => ({ content: JSON.stringify({ explanations: [{ fieldId: 'field-1', canonicalKey: 'certificates', summary: '证书', confidence: 1, reasonCode: 'LABEL_MATCH' }] }) }) };
  const send = (path, body) => handleRequest(new Request('https://relay.test' + path, { method: 'POST', headers: { authorization: 'Bearer fixture' }, body: JSON.stringify(body) }), options);
  assert.equal((await send('/v2/explain-fields', request)).status, 200);
  assert.equal((await send('/v1/explain-fields', request)).status, 400);
  assert.equal((await send('/v1/explain-fields', { ...request, schemaVersion: 1 })).status, 502);
});
