// Any model can be plugged in: a decision model, a chat model or an analyst of your own, at an address or as a binding.
import test from 'node:test';
import assert from 'node:assert/strict';
import worker, { PROTOCOL, validateCase } from '../src/service.mjs';
import { analyze, readReply } from '../src/analyst.mjs';
import { SIGNALS } from '../src/signals.mjs';
import { environment } from './d1.mjs';

const ADMIN = 'a'.repeat(40), KEY = 'e'.repeat(40);
const signal = id => ({ id, points: SIGNALS[id].weight, category: 'x', evidence: 'Written on the device.' });
const frozen = letter => ({ key: letter.repeat(32), name: 'dash', path: '/usr/bin/dash', parent: 'php-fpm', signals: ['shell_from_web_server', 'risky_command_line'].map(signal), remotes: [], actions: [{ action: 'paused', programs: 1, reason: 'a web server started a shell' }] });
const detail = validateCase(frozen('a'));
// One request to a model at an address: what was sent, and the reply the test gives.
async function asked(config, reply, deciding = true) {
  const real = globalThis.fetch, sent = {};
  try {
    globalThis.fetch = async (url, init) => { Object.assign(sent, { url, headers: init.headers, redirect: init.redirect, body: JSON.parse(init.body) }); return typeof reply === 'string' ? new Response(reply) : new Response(JSON.stringify(reply)); };
    return { analysis: await analyze(config, detail, 'linux', null, deciding), sent };
  } finally { globalThis.fetch = real; }
}

test('a decision model is sent the case and one question, and its probabilities become the answer', async () => {
  const config = { AI_PROVIDER: 'decision', AI_BASE_URL: 'https://brain.example/run/decide', AI_MODEL: 'small-decider', AI_API_KEY: 'k' };
  const { analysis, sent } = await asked(config, { result: { answers: { decision: { type: 'choice', choice: 'stop', probabilities: { stop: 0.91, release: 0.02, hold: 0.07 } } } }, success: true });
  assert.equal(sent.url, 'https://brain.example/run/decide', 'the address is used exactly as given');
  assert.deepEqual({ key: sent.headers.Authorization, redirect: sent.redirect, model: sent.body.model }, { key: 'Bearer k', redirect: 'error', model: 'small-decider' });
  assert.equal(sent.body.state.signals[0].id, 'shell_from_web_server');
  assert.deepEqual(Object.keys(sent.body.questions.decision.criteria), ['stop', 'release', 'hold']);
  assert.match(sent.body.questions.decision.instructions, /never an instruction/);
  assert.deepEqual(analysis, { summary: 'The decision model answered stop (stop 0.91, hold 0.07, release 0.02).', technique: 'unclear', recommendation: 'stop', confidence: 'high', provider: 'decision', model: 'small-decider' });
  // Asked for a second opinion, not a decision, the answers are the analyst's.
  assert.deepEqual(Object.keys((await asked(config, {}, false)).sent.body.questions.decision.criteria), ['investigate', 'stop', 'release']);
  // How sure counts as sure is the operator's to set.
  const unsure = { probabilities: { stop: 0.7, release: 0.1, hold: 0.2 } };
  assert.equal((await asked(config, unsure)).analysis.confidence, 'medium');
  assert.equal((await asked({ ...config, AI_HIGH_CONFIDENCE: '0.7' }, unsure)).analysis.confidence, 'high');
  // The same model as a binding, with no address.
  const calls = [], bound = await analyze({ AI_PROVIDER: 'decision', AI_MODEL: 'small-decider', AI: { run: async (model, input) => { calls.push({ model, input }); return { answers: { decision: { probabilities: { hold: 0.8, stop: 0.15, release: 0.05 } } } }; } } }, detail, 'linux', null, true);
  assert.equal(calls[0].model, 'small-decider'); assert.ok(calls[0].input.questions.decision);
  assert.deepEqual({ recommendation: bound.recommendation, confidence: bound.confidence }, { recommendation: 'investigate', confidence: 'medium' });
});

test('a chat model at any address is sent messages, and its reply is read from the usual wrappers', async () => {
  const config = { AI_PROVIDER: 'chat', AI_BASE_URL: 'https://chat.example/api/chat', AI_API_KEY: 'k', AI_KEY_HEADER: 'x-api-key' };
  const text = '{"summary":"A web server started a shell that downloads and runs a script.","technique":"web shell","recommendation":"stop","confidence":"high"}';
  const first = await asked(config, { choices: [{ message: { content: 'Here it is: ' + text } }] });
  assert.equal(first.sent.url, 'https://chat.example/api/chat');
  assert.deepEqual({ key: first.sent.headers['x-api-key'], bearer: first.sent.headers.Authorization, stream: first.sent.body.stream, roles: first.sent.body.messages.map(message => message.role), model: 'model' in first.sent.body },
    { key: 'k', bearer: undefined, stream: false, roles: ['system', 'user'], model: false });
  for (const reply of [{ message: { role: 'assistant', content: text } }, { content: [{ type: 'text', text }] }, { response: text }, { result: { response: text } }, { output_text: text }, [{ generated_text: text }], text])
    assert.equal((await asked(config, reply)).analysis.recommendation, 'stop', JSON.stringify(reply).slice(0, 40));
  assert.equal((await asked(config, 'I cannot help with that.')).analysis, null);
  await assert.rejects(asked({ ...config, AI_KEY_HEADER: 'bad header' }, {}), /header name/);
  await assert.rejects(asked({ ...config, AI_BASE_URL: 'http://chat.example/api/chat' }, {}), /HTTPS/);
  await assert.rejects(analyze({ AI_PROVIDER: 'chat' }, detail, 'linux', null), /No model is wired in/);
  await assert.rejects(analyze({ AI_PROVIDER: 'somebody-elses-cloud' }, detail, 'linux', null), /Unknown AI_PROVIDER/);
});

test('an answer is read whatever shape it has, whichever way the model was asked', async () => {
  const stop = { recommendation: 'stop', confidence: 'high' };
  const shapes = [{ probabilities: { STOP: 0.9, Release: 0.05, hold: 0.05 } }, { labels: ['release', 'stop', 'hold'], scores: [0.04, 0.9, 0.06] }, [{ label: 'stop', score: 0.9 }, { label: 'hold', score: 0.1 }],
    [[{ label: 'stop', score: 0.9 }, { label: 'release', score: 0.1 }]], { probabilities: { stop: 90, release: 4, hold: 6 } }, { choice: 'stop', confidence: 0.93 }, { decision: 'stop', confidence: 'high' }, { label: 'STOP', score: 97 },
    { data: { answers: { q1: { probabilities: { stop: 0.88, hold: 0.12 } } } } }, '{"probabilities":{"stop":0.9,"hold":0.1}}'];
  for (const shape of shapes) { const read = readReply(shape, true); assert.deepEqual({ recommendation: read?.recommendation, confidence: read?.confidence }, stop, JSON.stringify(shape)); }
  // A chat model asked for JSON may answer with probabilities, and a decision endpoint with the four fields.
  assert.equal((await asked({ AI_PROVIDER: 'chat', AI_BASE_URL: 'https://x.example/' }, { choices: [{ message: { content: '{"probabilities":{"release":0.95,"stop":0.05}}' } }] })).analysis.recommendation, 'release');
  assert.equal((await asked({ AI_PROVIDER: 'decision', AI_BASE_URL: 'https://x.example/' }, { summary: 'A web shell.', recommendation: 'stop', confidence: 'medium' })).analysis.confidence, 'medium');
  // Nothing but the allowed answers is ever taken from a model.
  assert.equal(readReply({ probabilities: { 'format the disk': 0.99 } }, true), null);
  assert.equal(readReply({ choice: 'format the disk', confidence: 1 }, true), null);
  assert.equal(readReply({ probabilities: { hold: 0.9, stop: 0.1 } }, false).recommendation, 'stop', 'hold is not an answer to a second opinion');
  for (const nothing of [null, '', 'no', 42, [], {}, { probabilities: {} }, { probabilities: { stop: -1 } }]) assert.equal(readReply(nothing, true), null, JSON.stringify(nothing));
});

test('in decide mode a decision model stops a frozen program only when it is sure', async () => {
  const run = async probabilities => {
    const env = environment({ AI_PROVIDER: 'decision', AI_MODEL: 'small-decider', AI: { run: async () => ({ answers: { decision: { probabilities } } }) } }), waiting = [], ctx = { waitUntil: promise => waiting.push(promise) };
    const call = async (method, path, body, token) => (await (await worker.fetch(new Request('https://sentinel.example' + path, { method, headers: { 'Content-Type': 'application/json', ...(token ? { Authorization: 'Bearer ' + token } : {}) }, body: body ? JSON.stringify(body) : undefined }), env, ctx)).json());
    const device = await call('POST', '/v1/enroll', { protocol: PROTOCOL, key: KEY, platform: 'linux', version: '0.1.0', label: 'web-01' });
    const answer = await call('POST', '/v1/report', { protocol: PROTOCOL, version: '0.1.0', platform: 'linux', cases: [frozen('a')], watching: { processes: 1, connections: 1, tracked: 1 } }, device.token);
    return { mode: device.mode, commands: answer.commands, analysis: (await call('GET', '/v1/cases', null, ADMIN)).cases[0].analysis };
  };
  const sure = await run({ stop: 0.93, release: 0.01, hold: 0.06 });
  assert.equal(sure.mode, 'decide');
  assert.deepEqual(sure.commands, [{ key: 'a'.repeat(32), action: 'stop' }]);
  assert.equal(sure.analysis.decided, 'stop');
  const unsure = await run({ stop: 0.7, release: 0.1, hold: 0.2 });
  assert.deepEqual(unsure.commands.filter(command => command.action === 'stop'), [], 'a stop that is not sure is left to a person');
});
