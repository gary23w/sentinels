// Try the service on your own machine without a Cloudflare account:
//   SENTINEL_ENROLL_KEY=<32+ chars> SENTINEL_ADMIN_TOKEN=<32+ chars> node local.mjs [port] [--memory neuron-db]
// The database lives in memory and is gone when this stops. Use it to evaluate, not to protect anything.
// --memory neuron-db (or SENTINEL_MEMORY=neuron-db) turns on the recall memory in src/memory.mjs; run "npm install" first.
import http from 'node:http';
import worker from './src/worker.mjs';
import { memoryChoice, neuronMemory } from './src/memory.mjs';
import { database } from './test/d1.mjs';

const need = name => { const value = process.env[name]; if (!value || value.length < 32) { console.error('Set ' + name + ' (at least 32 characters).'); process.exit(1); } return value; };
const env = { DB: database(), ENROLL_KEY: need('SENTINEL_ENROLL_KEY'), ADMIN_TOKEN: need('SENTINEL_ADMIN_TOKEN'), DATA_KEY: process.env.SENTINEL_DATA_KEY || need('SENTINEL_ADMIN_TOKEN') + '-local-data',
  RESPONSE_MODE: process.env.SENTINEL_RESPONSE_MODE, DECISION_FALLBACK: process.env.SENTINEL_DECISION_FALLBACK, DECISION_RELEASE: process.env.SENTINEL_DECISION_RELEASE, WATCHLIST: process.env.SENTINEL_WATCHLIST, FLEET_BLOCK: process.env.SENTINEL_FLEET_BLOCK, LEARN_FROM: process.env.SENTINEL_LEARN_FROM, TOR_EXITS: process.env.SENTINEL_TOR_EXITS, INGEST_TOKEN: process.env.SENTINEL_INGEST_TOKEN, ALERT_WEBHOOK_URL: process.env.SENTINEL_ALERT_WEBHOOK_URL, AI_PROVIDER: process.env.SENTINEL_AI_PROVIDER || 'none',
  AI_BASE_URL: process.env.SENTINEL_AI_BASE_URL, AI_MODEL: process.env.SENTINEL_AI_MODEL, AI_API_KEY: process.env.SENTINEL_AI_API_KEY };
try { if (memoryChoice(process.env.SENTINEL_MEMORY, process.argv.slice(2))) env.SENTINEL_MEMORY = await neuronMemory(env); } catch (error) { console.error(error.message); process.exit(1); }
const server = http.createServer(async (req, res) => {
  const chunks = []; for await (const chunk of req) chunks.push(chunk);
  const background = [];
  const response = await worker.fetch(new Request('http://127.0.0.1' + req.url, { method: req.method, headers: req.headers, body: ['GET', 'HEAD'].includes(req.method) ? undefined : Buffer.concat(chunks) }), env, { waitUntil: promise => background.push(promise) });
  res.writeHead(response.status, Object.fromEntries(response.headers)); res.end(await response.text());
  await Promise.allSettled(background);
});
server.listen(Number(process.argv[2]) || 8787, '127.0.0.1', () => console.log('Sentinel service listening on http://127.0.0.1:' + server.address().port + (env.SENTINEL_MEMORY ? ', remembering verdicts with ' + env.SENTINEL_MEMORY.engine : '')));
