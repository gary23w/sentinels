// The model run inside the service answers exactly as its PyTorch original. Needs the model repository cloned
// as ../model with model.onnx and benchmarks/parity.jsonl in it (the export and parity scripts there write
// them); without those files the checks are skipped, not failed.
import test from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { join } from 'node:path';
import { compact, optionTexts, render } from '../src/decisions.mjs';

const folder = join(fileURLToPath(new URL('.', import.meta.url)), '..', '..', 'model');
const ready = existsSync(join(folder, 'model.onnx')) && existsSync(join(folder, 'benchmarks', 'parity.jsonl'));

test('the state is rendered as Python renders it', () => {
  assert.equal(compact({ b: 1, a: [true, null, 'x'], c: { z: 0, y: '' } }), '{"a":[true,null,"x"],"b":1,"c":{"y":"","z":0}}');
  assert.equal(render('  text  '), 'text');
  assert.equal(render(null), '');
  assert.deepEqual(optionTexts({ stop: 'End it.', hold: 'hold', keep: '' }), { keys: ['stop', 'hold', 'keep'], texts: ['stop: End it.', 'hold', 'keep'] });
});

test('the in-process model answers like the PyTorch model on the parity rows', { skip: !ready && 'no model files beside the repository' }, async () => {
  const { localModel } = await import('../src/decisions.mjs');
  const model = await localModel(folder);
  const rows = readFileSync(join(folder, 'benchmarks', 'parity.jsonl'), 'utf8').trim().split('\n').map(line => JSON.parse(line));
  let worst = 0, disagreements = 0; const started = Date.now();
  for (const row of rows) {
    const out = await model.run('crivo-sentinel-v1', { state: row.state, questions: { decision: row.question } });
    const got = out.decision.probabilities, want = row.probabilities;
    assert.deepEqual(Object.keys(got).sort(), Object.keys(want).sort());
    for (const key of Object.keys(want)) worst = Math.max(worst, Math.abs(got[key] - want[key]));
    const best = Object.keys(want).reduce((a, b) => want[a] >= want[b] ? a : b);
    if (out.decision.choice !== best) disagreements += 1;
  }
  const ms = (Date.now() - started) / rows.length;
  console.log(`parity: ${rows.length} rows, ${disagreements} disagreements, largest probability difference ${worst.toExponential(2)}, ${ms.toFixed(0)} ms a row`);
  assert.equal(disagreements, 0);
  assert.ok(worst < 1e-4, 'probabilities within 1e-4 of PyTorch');
});

test('a question that is not a choice is refused', { skip: !ready && 'no model files beside the repository' }, async () => {
  const { localModel } = await import('../src/decisions.mjs');
  const model = await localModel(folder);
  await assert.rejects(model.run('x', { state: {}, questions: { q: { type: 'score', criteria: ['a'] } } }), /not a choice/);
});
