// A short walk through the Sentinel service's settings, above all the model part: which model decides what
// happens to a frozen program, or that none does. A few questions, then the answers go into the configuration file.
//
//   node setup.mjs <configuration file>              ask, then write the answers into that file (its other lines are kept)
//   node setup.mjs <configuration file> --print      ask, then print the lines instead, to put in by hand
//   node setup.mjs --install <answers file>          at install time: ask about the service too, write NAME=value
//                                                    lines for the installer (install.sh --wizard, garrett-service.ps1 -Wizard)
//   --no-memory      do not offer neuron-db (the bundle was built without it)
//
// The questions are read from standard input: a terminal, or piped answers when a script drives it. The
// installers hand it the terminal themselves when they run from a pipe (curl ... | sudo sh).
// Installed, this is:  sudo garrett-service setup   on Linux and   garrett-service.cmd setup   on Windows.
import { createInterface } from 'node:readline';
import { readFileSync, writeFileSync } from 'node:fs';
import { networkInterfaces } from 'node:os';

export const BUNDLED = 'crivo-sentinel-v1';

// The configuration file's lines are NAME=value. Keys given here replace their line, or are added at the end;
// everything else, comments included, stays as it was.
export function merge(text, settings) {
  const lines = text.replace(/\r/g, '').split('\n');
  if (lines.length && lines[lines.length - 1] === '') lines.pop();
  for (const [name, value] of Object.entries(settings)) {
    const line = name + '=' + value;
    let last = -1;
    lines.forEach((candidate, index) => { if (candidate.trim().startsWith(name + '=')) last = index; });
    if (last >= 0) lines[last] = line; else lines.push(line);
  }
  return lines.join('\n') + '\n';
}

export function readSettings(text) {
  const settings = {};
  for (const line of text.split(/\r?\n/)) { const found = /^([A-Z][A-Z0-9_]*)=(.*)$/.exec(line.trim()); if (found) settings[found[1]] = found[2]; }
  return settings;
}

// An address a model is posted to, as the user typed it. Returns what is wrong with it, or null when it will do.
// The service posts to HTTPS addresses only, and a key goes in AI_API_KEY, never in the address.
export function checkAddress(value) {
  let url;
  try { url = new URL(value); } catch { return 'That is not a whole address. It starts with https:// and names the host, like https://models.example.net/decide'; }
  if (url.protocol !== 'https:') return 'The service only posts to HTTPS addresses, so it has to start with https://';
  if (url.username || url.password) return 'Leave the key out of the address; the next question asks for it.';
  if (url.hash) return 'An address with # in it would be cut there; leave the # part out.';
  return null;
}

// The settings that follow from the answers. Every model-related key is written, so switching models leaves
// nothing of the old one behind.
export function settingsFor(answers, options = {}) {
  const out = { AI_PROVIDER: 'none', AI_MODEL: '', MODEL_DIR: '', AI_BASE_URL: '', AI_API_KEY: '', AI_KEY_HEADER: '', AI_CA_CERT: '' };
  if (answers.model === 'bundled') {
    out.AI_PROVIDER = 'decision'; out.AI_MODEL = BUNDLED; out.MODEL_DIR = options.modelDir || '';
  } else if (answers.model !== 'none') {
    out.AI_PROVIDER = answers.model; out.AI_BASE_URL = answers.address || ''; out.AI_MODEL = answers.name || '';
    out.AI_API_KEY = answers.key || ''; out.AI_KEY_HEADER = answers.key ? answers.header || '' : ''; out.AI_CA_CERT = answers.ca || '';
  }
  if (answers.model !== 'none') {
    out.AI_HIGH_CONFIDENCE = answers.confidence || '0.85';
    out.DECISION_RELEASE = answers.release ? 'high-confidence' : '';
    out.DECISION_FALLBACK = answers.fallback || 'kill';
  }
  out.RESPONSE_MODE = answers.mode || '';
  return out;
}

function firstAddress() {
  for (const list of Object.values(networkInterfaces())) for (const entry of list || []) if (entry.family === 'IPv4' && !entry.internal) return entry.address;
  return '';
}

export class Prompter {
  constructor(input = process.stdin, output = process.stderr) {
    this.input = input; this.output = output; this.tty = !!input.isTTY;
    this.rl = createInterface({ input, output: this.tty ? output : undefined, terminal: this.tty });
    this.lines = []; this.waiting = []; this.closed = false;
    if (!this.tty) this.rl.on('line', line => { const next = this.waiting.shift(); if (next) next(line); else this.lines.push(line); });
    this.rl.on('close', () => { this.closed = true; while (this.waiting.length) this.waiting.shift()(''); });
  }
  say(text = '') { this.output.write(text + '\n'); }
  async ask(question, fallback = '', { hidden = false } = {}) {
    const prompt = question + (fallback ? ' [' + fallback + ']' : '') + ': ';
    let answer;
    if (!this.tty) {
      this.output.write(prompt);
      answer = this.lines.length ? this.lines.shift() : this.closed ? '' : await new Promise(resolve => this.waiting.push(resolve));
      this.output.write((hidden && answer ? '(hidden)' : answer) + '\n');
    } else if (hidden) {
      answer = await this.secret(prompt);
    } else {
      answer = await new Promise(resolve => this.rl.question(prompt, resolve));
    }
    answer = answer.trim();
    return answer === '' ? fallback : answer;
  }
  // A key is typed without an echo.
  secret(prompt) {
    return new Promise(resolve => {
      this.output.write(prompt);
      const { input } = this; let typed = '';
      this.rl.pause();
      input.setRawMode(true); input.resume();
      const onData = chunk => {
        for (const char of chunk.toString('utf8')) {
          if (char === '\u0003') { input.setRawMode(false); this.output.write('\n'); process.exit(130); }
          if (char === '\r' || char === '\n') { input.setRawMode(false); input.off('data', onData); this.output.write('\n'); this.rl.resume(); resolve(typed); return; }
          if (char === '\u007f' || char === '\b') typed = typed.slice(0, -1); else typed += char;
        }
      };
      input.on('data', onData);
    });
  }
  async choose(question, choices, fallback) {
    this.say(question);
    choices.forEach((choice, index) => this.say('  ' + (index + 1) + ') ' + choice.text));
    for (;;) {
      const answer = await this.ask('Pick one', String(choices.findIndex(choice => choice.value === fallback) + 1));
      const index = Number(answer) - 1;
      if (choices[index]) return choices[index].value;
      const named = choices.find(choice => choice.value === answer);
      if (named) return named.value;
      this.say('Answer with a number from 1 to ' + choices.length + '.');
    }
  }
  async yes(question, fallback = false) {
    for (;;) {
      const answer = (await this.ask(question + ' (yes/no)', fallback ? 'yes' : 'no')).toLowerCase();
      if (['y', 'yes'].includes(answer)) return true;
      if (['n', 'no'].includes(answer)) return false;
      this.say('Answer yes or no.');
    }
  }
  close() { this.rl.close(); }
}

export async function interview(p, { install = false, memory = true, current = {} } = {}) {
  const answers = {};
  if (install) {
    p.say(''); p.say('The service.');
    for (;;) { answers.port = await p.ask('Port the service listens on', '8443'); if (/^\d{1,5}$/.test(answers.port) && Number(answers.port) > 0 && Number(answers.port) < 65536) break; p.say('A port is a number from 1 to 65535.'); }
    answers.address = await p.ask('Name or address other machines reach this one by', firstAddress());
    answers.memory = memory && await p.yes("Remember operators' verdicts and show each new case the nearest ones (neuron-db)?", false) ? 'neuron-db' : 'off';
  }
  p.say(''); p.say('The model. When a machine freezes a hostile program, a model can say what happens to it: stop, release, or hold for you.');
  const choices = [
    { value: 'bundled', text: BUNDLED + ', the model that comes with Sentinels. It runs inside the service, on this machine; nothing leaves it.' },
    { value: 'decision', text: 'A decision model of my own, at an HTTPS address: it is sent the case and the allowed answers, and answers a probability for each.' },
    { value: 'chat', text: 'A chat model, at an HTTPS address: it is sent messages and answers in text.' },
    { value: 'custom', text: 'My own reasoning: a program of mine at an HTTPS address that takes the case and answers {"summary", "technique", "recommendation", "confidence"}.' },
    { value: 'none', text: 'No model. Machines end hostile programs on their own.' }];
  const was = !current.AI_PROVIDER ? 'bundled' : current.AI_PROVIDER === 'none' ? 'none' : current.AI_MODEL === BUNDLED ? 'bundled' : current.AI_PROVIDER;
  answers.model = await p.choose('Which model decides?', choices, choices.some(choice => choice.value === was) ? was : 'bundled');
  if (!['bundled', 'none'].includes(answers.model)) {
    for (;;) {
      answers.address = await p.ask('Its HTTPS address, exactly as the request should be posted to it', current.AI_BASE_URL || '');
      const problem = checkAddress(answers.address); if (!problem) break; p.say(problem);
    }
    answers.name = await p.ask('Model name to send with each request, if it wants one', current.AI_MODEL === BUNDLED ? '' : current.AI_MODEL || '');
    answers.key = await p.ask('API key, if it wants one (not shown as you type)', '', { hidden: true });
    if (answers.key) answers.header = await p.ask('Header the key goes in; leave it empty for "Authorization: Bearer <key>"', current.AI_KEY_HEADER || '');
    answers.ca = await p.ask('A certificate file (PEM) to trust for that address, if its certificate is your own; empty otherwise', current.AI_MODEL === BUNDLED ? '' : current.AI_CA_CERT || '');
  }
  if (answers.model !== 'none') {
    p.say(''); p.say('How much the model may decide.');
    for (;;) { answers.confidence = await p.ask('How sure it must be before the service acts on a stop or release, from 0.5 to 1', current.AI_HIGH_CONFIDENCE || '0.85'); const n = Number(answers.confidence); if (n >= 0.5 && n <= 1) break; p.say('A number from 0.5 to 1.'); }
    answers.release = await p.yes('May a confident "release" let a frozen program go without an operator?', current.DECISION_RELEASE === 'high-confidence');
    answers.fallback = await p.choose('If the model does not answer within 8 seconds:', [{ value: 'kill', text: 'end the frozen program (kill)' }, { value: 'hold', text: 'keep it frozen for an operator (hold)' }], current.DECISION_FALLBACK === 'hold' ? 'hold' : 'kill');
  }
  p.say('');
  const modes = [{ value: '', text: 'the default: decide with the model' + (answers.model === 'none' ? ', and since there is none, kill' : '') },
    { value: 'kill', text: 'kill: end it, and everything it started, at once' }, { value: 'pause', text: 'pause: freeze it and wait for an operator' },
    { value: 'decide', text: 'decide: freeze it and let the model decide' }, { value: 'report', text: 'report: only tell you' }];
  answers.mode = await p.choose('What machines do with a hostile program:', modes, current.RESPONSE_MODE && modes.some(mode => mode.value === current.RESPONSE_MODE) ? current.RESPONSE_MODE : '');
  return answers;
}

export async function main(argv, p = null) {
  const flags = new Set(argv.filter(arg => arg.startsWith('--'))), files = argv.filter(arg => !arg.startsWith('--'));
  const install = flags.has('--install'), print = flags.has('--print');
  const file = files[0];
  if (!file) { console.error('Usage: node setup.mjs <configuration file> [--print]   or   node setup.mjs --install <answers file>'); return 2; }
  let text = '';
  if (!install) { try { text = readFileSync(file, 'utf8'); } catch { console.error('No configuration file at ' + file + '.'); return 1; } }
  const current = readSettings(text);
  const own = !p; p = p || new Prompter();
  try {
    p.say('Sentinel service setup. Press Enter to keep what is in brackets.');
    const answers = await interview(p, { install, memory: !flags.has('--no-memory'), current });
    // The model that comes with Sentinels lives where the installer put it; on Windows the installer fills that in.
    const settings = settingsFor(answers, { modelDir: current.MODEL_DIR || (process.platform === 'win32' ? '' : '/usr/lib/garrett-service/model') });
    const lines = Object.entries(settings).map(([name, value]) => name + '=' + value);
    p.say(''); p.say('These lines say it:'); for (const line of lines) p.say('  ' + (line.startsWith('AI_API_KEY=') && settings.AI_API_KEY ? 'AI_API_KEY=(hidden)' : line));
    if (install) {
      const extra = { PORT: answers.port, ADDRESS: answers.address, MEMORY: answers.memory, MODEL: answers.model === 'bundled' ? BUNDLED : 'off' };
      writeFileSync(file, Object.entries({ ...extra, ...settings }).map(([name, value]) => name + '=' + value).join('\n') + '\n', { mode: 0o600 });
      return 0;
    }
    if (print || !await p.yes('Write them into ' + file + '?', true)) {
      p.say(''); p.say('Nothing was written. Put these lines in ' + file + ' yourself and restart the service:'); for (const line of lines) p.say('  ' + line);
      return 0;
    }
    writeFileSync(file, merge(text, settings));
    p.say(''); p.say('Written to ' + file + '. Restart the service for it to take effect.');
    return 0;
  } finally { if (own) p.close(); }
}

const entry = process.argv[1] ? new URL('file://' + (process.platform === 'win32' ? '/' : '') + process.argv[1].replace(/\\/g, '/')).href : '';
if (import.meta.url === entry) main(process.argv.slice(2)).then(code => process.exit(code), error => { console.error(error.message); process.exit(1); });
