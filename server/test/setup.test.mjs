// The setup wizard: what it writes for each kind of model, driven from a pipe as an installer or a test would.
import test from 'node:test';
import assert from 'node:assert/strict';
import { PassThrough } from 'node:stream';
import { mkdtempSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { BUNDLED, Prompter, checkAddress, interview, main, merge, readSettings, settingsFor } from '../setup.mjs';

const run = async (answers, options = {}) => {
  const input = new PassThrough(), output = new PassThrough(); let shown = '';
  output.on('data', chunk => { shown += chunk; });
  const p = new Prompter(input, output);
  input.end(answers.join('\n') + '\n');
  const result = await interview(p, options);
  p.close();
  return { result, shown };
};

test('merge replaces a line in place and adds the rest, keeping comments', () => {
  const text = '# keep me\nPORT=8443\nAI_PROVIDER=none\nMEMORY=off\n';
  const out = merge(text, { AI_PROVIDER: 'decision', AI_BASE_URL: 'https://127.0.0.1:8791/decide' });
  assert.equal(out, '# keep me\nPORT=8443\nAI_PROVIDER=decision\nMEMORY=off\nAI_BASE_URL=https://127.0.0.1:8791/decide\n');
  assert.deepEqual(readSettings(out), { PORT: '8443', AI_PROVIDER: 'decision', MEMORY: 'off', AI_BASE_URL: 'https://127.0.0.1:8791/decide' });
});

test('the defaults pick the model that comes with Sentinels', async () => {
  const { result } = await run(['', '', '', '', '']);
  assert.equal(result.model, 'bundled');
  const settings = settingsFor(result, { modelDir: '/usr/lib/garrett-service/model' });
  assert.equal(settings.AI_PROVIDER, 'decision');
  assert.equal(settings.AI_MODEL, BUNDLED);
  assert.equal(settings.MODEL_DIR, '/usr/lib/garrett-service/model');
  assert.equal(settings.AI_BASE_URL, '');
  assert.equal(settings.AI_CA_CERT, '');
  assert.equal(settings.AI_HIGH_CONFIDENCE, '0.85');
  assert.equal(settings.DECISION_RELEASE, '');
  assert.equal(settings.DECISION_FALLBACK, 'kill');
  assert.equal(settings.RESPONSE_MODE, '');
});

test('a model of your own: address, name, key, and how much it may decide', async () => {
  const { result, shown } = await run(['3', 'https://models.example.net/v1/chat/completions', 'my-model', 'a-secret', 'X-Api-Key', '', '0.9', 'yes', 'hold', 'decide']);
  assert.equal(result.model, 'chat');
  const settings = settingsFor(result);
  assert.deepEqual(settings, { AI_PROVIDER: 'chat', AI_MODEL: 'my-model', MODEL_DIR: '', AI_BASE_URL: 'https://models.example.net/v1/chat/completions', AI_API_KEY: 'a-secret', AI_KEY_HEADER: 'X-Api-Key', AI_CA_CERT: '',
    AI_HIGH_CONFIDENCE: '0.9', DECISION_RELEASE: 'high-confidence', DECISION_FALLBACK: 'hold', RESPONSE_MODE: 'decide' });
  assert.ok(!shown.includes('a-secret'), 'the key is not echoed');
});

test('no model at all leaves nothing of an old one behind', async () => {
  const { result } = await run(['5', '']);
  const settings = settingsFor(result);
  assert.deepEqual(settings, { AI_PROVIDER: 'none', AI_MODEL: '', MODEL_DIR: '', AI_BASE_URL: '', AI_API_KEY: '', AI_KEY_HEADER: '', AI_CA_CERT: '', RESPONSE_MODE: '' });
});

test('the current settings are the defaults when the wizard runs again', async () => {
  const current = { AI_PROVIDER: 'custom', AI_BASE_URL: 'https://mine.example.net/analyst', AI_HIGH_CONFIDENCE: '0.7', DECISION_FALLBACK: 'hold', RESPONSE_MODE: 'pause' };
  const { result } = await run(['', '', '', '', '', '', '', ''], { current });
  assert.equal(result.model, 'custom');
  assert.equal(result.address, 'https://mine.example.net/analyst');
  assert.equal(result.confidence, '0.7');
  assert.equal(result.fallback, 'hold');
  assert.equal(result.mode, 'pause');
});

test('a bad answer is asked again', async () => {
  const { result, shown } = await run(['9', '1', '2', '0.85', 'maybe', 'no', '', '']);
  assert.equal(result.model, 'bundled');
  assert.ok(shown.includes('Answer with a number from 1 to 5.'));
  assert.ok(shown.includes('A number from 0.5 to 1.'));
  assert.ok(shown.includes('Answer yes or no.'));
});

test('an address a model is posted to is checked', () => {
  assert.equal(checkAddress('https://models.example.net/decide'), null);
  assert.equal(checkAddress('https://127.0.0.1:8791/decide?route=a'), null);
  assert.match(checkAddress('models.example.net/decide'), /whole address/);
  assert.match(checkAddress('http://models.example.net/decide'), /HTTPS/);
  assert.match(checkAddress('https://user:key@models.example.net/decide'), /key/);
  assert.match(checkAddress('https://models.example.net/decide#frag'), /#/);
});

test('install mode writes the answers file the installer reads', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'sentinel-setup-')), file = join(dir, 'answers');
  const input = new PassThrough(), output = new PassThrough(); output.resume();
  input.end(['9000', 'sentinel.example.internal', '', '', '', '', ''].join('\n') + '\n');
  const p = new Prompter(input, output);
  assert.equal(await main(['--install', file, '--no-memory'], p), 0);
  p.close();
  const written = readSettings(readFileSync(file, 'utf8'));
  assert.equal(written.PORT, '9000');
  assert.equal(written.ADDRESS, 'sentinel.example.internal');
  assert.equal(written.MEMORY, 'off');
  assert.equal(written.MODEL, BUNDLED);
  assert.equal(written.AI_PROVIDER, 'decision');
  assert.equal(written.AI_BASE_URL, '');
});

test('on an installed service the answers go into the configuration file, or are printed to put in by hand', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'sentinel-setup-')), file = join(dir, 'service.conf');
  writeFileSync(file, 'PORT=8443\nTLS_CERT=/etc/garrett-service/tls.crt\nAI_PROVIDER=none\n');
  let input = new PassThrough(), output = new PassThrough(); output.resume();
  input.end(['2', 'https://models.example.net/decide', '', '', '', '', 'no', '', '', 'yes'].join('\n') + '\n');
  let p = new Prompter(input, output);
  assert.equal(await main([file], p), 0);
  p.close();
  const written = readSettings(readFileSync(file, 'utf8'));
  assert.equal(written.PORT, '8443');
  assert.equal(written.AI_PROVIDER, 'decision');
  assert.equal(written.AI_BASE_URL, 'https://models.example.net/decide');
  assert.equal(written.AI_CA_CERT, '');
  input = new PassThrough(); output = new PassThrough(); let shown = ''; output.on('data', chunk => { shown += chunk; });
  input.end(['5', ''].join('\n') + '\n');
  p = new Prompter(input, output);
  assert.equal(await main([file, '--print'], p), 0);
  p.close();
  assert.equal(readSettings(readFileSync(file, 'utf8')).AI_PROVIDER, 'decision', 'nothing was written');
  assert.ok(shown.includes('Nothing was written') && shown.includes('AI_PROVIDER=none'));
});
