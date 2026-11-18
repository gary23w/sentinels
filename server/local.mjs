// Try the service on your own machine without a Cloudflare account:
//   SENTINEL_ENROLL_KEY=<32+ chars> SENTINEL_ADMIN_TOKEN=<32+ chars> node local.mjs [port] [--memory neuron-db]
// The database lives in memory and is gone when this stops. Use it to evaluate, not to protect anything.
// --memory neuron-db (or SENTINEL_MEMORY=neuron-db) turns on the recall memory in src/memory.mjs; run "npm install" first.
//
// SENTINEL_LOG=on enables JSON Lines diagnostics on standard error; a file path also appends to that file.
// SENTINEL_HOUSEKEEP=<seconds> runs housekeeping on a timer.
import http from 'node:http';
import worker from './src/worker.mjs';
import { memoryChoice, neuronMemory } from './src/memory.mjs';
import { housekeeping } from './src/service.mjs';
import { database } from './test/d1.mjs';
import { createDevLog, errorCode, requestLog } from './src/dev-log.mjs';

const need = name => { const value = process.env[name]; if (!value || value.length < 32) { console.error('Set ' + name + ' (at least 32 characters).'); process.exit(1); } return value; };
const env = { DB: database(), ENROLL_KEY: need('SENTINEL_ENROLL_KEY'), ADMIN_TOKEN: need('SENTINEL_ADMIN_TOKEN'), DATA_KEY: process.env.SENTINEL_DATA_KEY || need('SENTINEL_ADMIN_TOKEN') + '-local-data',
  RESPONSE_MODE: process.env.SENTINEL_RESPONSE_MODE, DECISION_FALLBACK: process.env.SENTINEL_DECISION_FALLBACK, DECISION_RELEASE: process.env.SENTINEL_DECISION_RELEASE, WATCHLIST: process.env.SENTINEL_WATCHLIST, FLEET_BLOCK: process.env.SENTINEL_FLEET_BLOCK, LEARN_FROM: process.env.SENTINEL_LEARN_FROM, TOR_EXITS: process.env.SENTINEL_TOR_EXITS, INGEST_TOKEN: process.env.SENTINEL_INGEST_TOKEN, ALERT_WEBHOOK_URL: process.env.SENTINEL_ALERT_WEBHOOK_URL, AI_PROVIDER: process.env.SENTINEL_AI_PROVIDER || 'none',
  AI_BASE_URL: process.env.SENTINEL_AI_BASE_URL, AI_MODEL: process.env.SENTINEL_AI_MODEL, AI_API_KEY: process.env.SENTINEL_AI_API_KEY,
  SILENT_CASES: process.env.SENTINEL_SILENT_CASES };
try { if (memoryChoice(process.env.SENTINEL_MEMORY, process.argv.slice(2))) env.SENTINEL_MEMORY = await neuronMemory(env); } catch (error) { console.error(error.message); process.exit(1); }
const log = createDevLog(process.env.SENTINEL_LOG);
const waitUntil = promise => {
  Promise.resolve(promise).catch(error => log?.('background_error', { error: errorCode(error) }));
};

const server = http.createServer(async (req, res) => {
  const trace = requestLog(log, req);
  let status = 500;
  try {
    const chunks = [];
    for await (const chunk of req) chunks.push(chunk);
    const request = new Request('http://127.0.0.1' + req.url, { method: req.method, headers: req.headers, body: ['GET', 'HEAD'].includes(req.method) ? undefined : Buffer.concat(chunks) });
    const response = await worker.fetch(request, env, { waitUntil, diagnostics: trace?.details });
    const body = await response.text();
    status = response.status;
    res.writeHead(status, Object.fromEntries(response.headers)); res.end(body);
  } catch (error) {
    if (!res.headersSent) { status = 500; res.writeHead(status, { 'Content-Type': 'application/json' }); }
    res.end('{"error":"The request could not be completed."}');
    if (trace) trace.details.error = errorCode(error);
  } finally {
    trace?.finish(status);
  }
});
server.listen(Number(process.argv[2]) || 8787, '127.0.0.1', () => {
  console.log('Sentinel service listening on http://127.0.0.1:' + server.address().port + (env.SENTINEL_MEMORY ? ', remembering verdicts with ' + env.SENTINEL_MEMORY.engine : ''));
  log?.('listening', { port: server.address().port });
});

const every = Number(process.env.SENTINEL_HOUSEKEEP);
if (Number.isFinite(every) && every >= 1 && every * 1000 <= 2 ** 31 - 1) {
  const sweep = async () => {
    try { const result = await housekeeping(env, { waitUntil }); log?.('housekeeping', result); }
    catch (error) { log?.('housekeeping_error', { error: errorCode(error) }); }
    setTimeout(sweep, every * 1000).unref();
  };
  setTimeout(sweep, every * 1000).unref();
}
