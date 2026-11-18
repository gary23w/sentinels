// The optional recall memory (src/memory.mjs) against the neuron-db release that "npm install" brought in.
// Without the package these tests are skipped: the service does not need it unless MEMORY is set.
import test from 'node:test';
import assert from 'node:assert/strict';
import { memoryChoice, neuronMemory } from '../src/memory.mjs';
import { recallSimilar, rememberVerdict, resetLearning } from '../src/learning.mjs';
import { analystRequest, instructionsFor } from '../src/analyst.mjs';
import { unseal } from '../src/util.mjs';
import { environment } from './d1.mjs';

let installed = true;
try { await import('@gary23w/neuron-db'); } catch { installed = false; }
const skip = installed ? false : 'the neuron-db package is not installed (npm install)';
const detail = (...ids) => ({ name: 'updater', path: '/tmp/x/updater', signals: ids.map(id => ({ id, points: 3, evidence: 'secret-evidence' })) });

test('the memory is off unless asked for, by setting or by argument, and an unknown engine is refused', () => {
  assert.equal(memoryChoice(undefined, []), null);
  assert.equal(memoryChoice('off', []), null);
  assert.equal(memoryChoice('neuron-db', []), 'neuron-db');
  assert.equal(memoryChoice(undefined, ['8787', '--memory', 'neuron-db']), 'neuron-db');
  assert.equal(memoryChoice(undefined, ['--memory=Neuron-DB']), 'neuron-db');
  assert.equal(memoryChoice('neuron-db', ['--memory', 'off']), null, 'the command line has the last word');
  assert.throws(() => memoryChoice('something-else', []), /Unknown memory/);
});

test('a case is shown the remembered verdicts nearest to it, repeats counted once, and only as shapes', { skip }, async () => {
  const env = environment(); env.SENTINEL_MEMORY = await neuronMemory(env);
  for (let number = 0; number < 3; number++) await rememberVerdict(env, 'linux', detail('shell_from_web_server', 'risky_command_line'), 'confirmed');
  await rememberVerdict(env, 'windows', detail('shell_from_web_server', 'risky_command_line'), 'dismissed');
  await rememberVerdict(env, 'linux', detail('tor_routing', 'drop_or_tunnel_host'), 'dismissed');
  assert.equal(env.SENTINEL_MEMORY.count(), 3);
  const similar = await recallSimilar(env, 'linux', detail('shell_from_web_server', 'risky_command_line', 'unusual_port'));
  assert.deepEqual(similar.recalled, ['confirmed case on linux with risky_command_line shell_from_web_server (3 times)', 'dismissed case on windows with risky_command_line shell_from_web_server']);
  // The model is given each remembered verdict with how it relates to the case in front of it.
  const told = (ids, platform, recalled) => analystRequest(detail(...ids), platform, { dismissed: 0, confirmed: 0, recalled }).similar_cases_before.remembered_verdicts;
  const pair = ['risky_command_line', 'shell_from_web_server'];
  assert.deepEqual(told(pair, 'linux', similar.recalled), [
    { verdict: 'confirmed_attack', times: 3, platform: 'linux', signals: pair, this_case_also_has: [], covers_this_case: true },
    { verdict: 'marked_ours', times: 1, platform: 'windows', signals: pair, this_case_also_has: [], covers_this_case: false }]);
  assert.equal(told(pair, 'windows', similar.recalled)[0].covers_this_case, false, 'another platform does not cover it');
  assert.deepEqual(told([...pair, 'unusual_port'], 'linux', similar.recalled)[0].this_case_also_has, ['unusual_port']);
  assert.equal(told([...pair, 'unusual_port'], 'linux', similar.recalled)[0].covers_this_case, false, 'a case with more signals is not covered');
  const split = ['confirmed case on linux with risky_command_line shell_from_web_server (3 times)', 'dismissed case on linux with risky_command_line shell_from_web_server (2 times)'];
  assert.deepEqual(told(pair, 'linux', split).map(item => item.covers_this_case), [false, false], 'operators who did not agree cover nothing');
  assert.ok(instructionsFor(analystRequest(detail(...pair), 'linux', similar), true).includes('remembered_verdicts'));
  assert.ok(!instructionsFor(analystRequest(detail(...pair), 'linux', { dismissed: 0, confirmed: 0, recalled: [] }), true).includes('remembered_verdicts'));
  // A stop the decision model ordered is not remembered as an operator's verdict.
  await rememberVerdict(env, 'linux', detail('port_scan', 'lateral_sweep'), 'confirmed', 'model');
  assert.equal(env.SENTINEL_MEMORY.count(), 3);
  assert.equal('remembered_verdicts' in analystRequest(detail('beaconing'), 'linux', { dismissed: 0, confirmed: 0, recalled: [] }).similar_cases_before, false);
  const kept = JSON.stringify(await unseal(JSON.parse((await env.DB.prepare('SELECT facts FROM memory WHERE id=1').first()).facts)[0], env.DATA_KEY));
  assert.ok(!kept.includes('updater') && !kept.includes('/tmp') && !kept.includes('secret-evidence'), kept);
});

test('signal ids that share a stem are not taken for each other, and an unrelated case recalls nothing', { skip }, async () => {
  const env = environment(); env.SENTINEL_MEMORY = await neuronMemory(env);
  await rememberVerdict(env, 'windows', detail('boot_entry_added'), 'confirmed');
  await rememberVerdict(env, 'linux', detail('web_injection_attempt', 'web_fuzzing'), 'confirmed');
  assert.deepEqual((await recallSimilar(env, 'windows', detail('boot_entry_removed'))).recalled, []);
  assert.deepEqual((await recallSimilar(env, 'linux', detail('web_injection_answered'))).recalled, []);
  assert.deepEqual((await recallSimilar(env, 'windows', detail('beaconing', 'unusual_port'))).recalled, []);
  assert.deepEqual((await recallSimilar(env, 'windows', detail('boot_entry_added'))).recalled, ['confirmed case on windows with boot_entry_added']);
});

test('the memory survives a restart, is sealed at rest, and is forgotten with everything else learned', { skip }, async () => {
  const env = environment(); env.SENTINEL_MEMORY = await neuronMemory(env);
  await rememberVerdict(env, 'linux', detail('beaconing', 'runs_from_temp'), 'confirmed');
  const stored = (await env.DB.prepare('SELECT facts FROM memory WHERE id=1').first()).facts;
  assert.ok(stored.startsWith('["v1.') && !stored.includes('beaconing'));
  const restarted = { ...env, SENTINEL_MEMORY: undefined }; restarted.SENTINEL_MEMORY = await neuronMemory(restarted);
  assert.deepEqual((await recallSimilar(restarted, 'linux', detail('beaconing', 'runs_from_temp'))).recalled, ['confirmed case on linux with beaconing runs_from_temp']);
  await resetLearning(restarted);
  assert.equal(restarted.SENTINEL_MEMORY.count(), 0);
  assert.deepEqual((await recallSimilar(restarted, 'linux', detail('beaconing', 'runs_from_temp'))).recalled, []);
  assert.equal(await env.DB.prepare('SELECT facts FROM memory WHERE id=1').first(), null);
});

test('the memory keeps the newest sentences and no more than its limit', { skip }, async () => {
  const MEMORY_MAX = 150, env = environment(), memory = await neuronMemory(env, MEMORY_MAX);
  for (let number = 0; number < MEMORY_MAX + 5; number++) await memory.remember('confirmed case on linux with beaconing n' + number);
  assert.equal(memory.count(), MEMORY_MAX);
  assert.deepEqual(await memory.recall('case on linux with n0', 3, { platform: 'linux', shape: ['n0'] }), []);
  assert.deepEqual(await memory.recall('case on linux with n' + (MEMORY_MAX + 4), 3, { platform: 'linux', shape: ['n' + (MEMORY_MAX + 4)] }), ['confirmed case on linux with beaconing n' + (MEMORY_MAX + 4)]);
});
