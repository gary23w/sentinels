// Run the Sentinel service on your own machine, for good: a database file that survives restarts, HTTPS with
// your own certificate, and the same housekeeping the Cloudflare deployment runs on a timer.
//
//   node serve.mjs /etc/garrett-service/service.conf
//
// The one-line installers (service.sh, service.ps1) write that file and start this for you. Its lines are NAME=value:
//   ENROLL_KEY, ADMIN_TOKEN, DATA_KEY   required, 32+ characters each (see the README)
//   DATABASE                            path of the database file
//   PORT                                default 8443
//   TLS_CERT and TLS_KEY                PEM files, or TLS_PFX and TLS_PASSPHRASE
//   MEMORY                              neuron-db to remember verdicts and recall the nearest (see src/memory.mjs); off by
//                                       default. The same on the command line:  node serve.mjs <file> --memory neuron-db
//   MODEL_DIR                           the folder of the decision model that comes with Sentinels (model.onnx and its
//                                       tokenizer): with AI_PROVIDER=decision and no AI_BASE_URL, the service runs it itself,
//                                       in this process. The installer sets this up; it needs the packages the bundles carry.
//   AI_CA_CERT                          a PEM certificate to trust for AI_BASE_URL, when a model of your own has one
//   anything else                       the same settings wrangler.example.jsonc documents (RESPONSE_MODE, FLEET_BLOCK, ...)
// Needs Node.js 22.13 or newer. No packages to install, unless MEMORY is set: then run "npm install" in this folder.
import https from 'node:https';
import { getCACertificates, setDefaultCACertificates } from 'node:tls';
import { readFileSync } from 'node:fs';
import worker from './src/worker.mjs';
import { database } from './sqlite.mjs';
import { memoryChoice, neuronMemory } from './src/memory.mjs';

const MAX_BODY = 1024 * 1024;
const file = process.argv[2];
if (!file) { console.error('Usage: node serve.mjs <configuration file>'); process.exit(1); }
const settings = {};
for (const line of readFileSync(file, 'utf8').split(/\r?\n/)) { const found = /^([A-Z][A-Z0-9_]*)=(.*)$/.exec(line.trim()); if (found) settings[found[1]] = found[2]; }
for (const name of ['ENROLL_KEY', 'ADMIN_TOKEN', 'DATA_KEY']) if (!settings[name] || settings[name].length < 32) { console.error(name + ' must be set in ' + file + ' (at least 32 characters).'); process.exit(1); }
if (!settings.DATABASE) { console.error('DATABASE must be set in ' + file + '.'); process.exit(1); }
const tls = settings.TLS_PFX ? { pfx: readFileSync(settings.TLS_PFX), passphrase: settings.TLS_PASSPHRASE || '' }
  : settings.TLS_CERT && settings.TLS_KEY ? { cert: readFileSync(settings.TLS_CERT), key: readFileSync(settings.TLS_KEY) } : null;
if (!tls) { console.error('Set TLS_CERT and TLS_KEY, or TLS_PFX, in ' + file + '. Agents only talk to a service over HTTPS.'); process.exit(1); }

const { PORT, DATABASE, TLS_CERT, TLS_KEY, TLS_PFX, TLS_PASSPHRASE, ADDRESS, MEMORY, AI_CA_CERT, MODEL_DIR, ...rest } = settings;
if (AI_CA_CERT) {
  if (typeof setDefaultCACertificates !== 'function') { console.error('This Node.js cannot be given an extra certificate for AI_CA_CERT. Start it with NODE_EXTRA_CA_CERTS=' + AI_CA_CERT + ' instead, or use a newer Node.js.'); process.exit(1); }
  try { setDefaultCACertificates([...getCACertificates('default'), readFileSync(AI_CA_CERT, 'utf8')]); } catch (error) { console.error('AI_CA_CERT could not be read: ' + error.message); process.exit(1); }
}
const env = { AI_PROVIDER: 'none', ...rest, DB: database(DATABASE) };
try { if (memoryChoice(MEMORY, process.argv.slice(3))) env.SENTINEL_MEMORY = await neuronMemory(env); } catch (error) { console.error(error.message); process.exit(1); }
if (MODEL_DIR && env.AI_PROVIDER === 'decision' && !env.AI_BASE_URL) {
  try { env.AI = await (await import('./src/decisions.mjs')).localModel(MODEL_DIR); if (!env.AI_MODEL) env.AI_MODEL = env.AI.name; }
  catch (error) { console.error('The decision model in ' + MODEL_DIR + ' could not be loaded: ' + error.message); process.exit(1); }
}
const background = promise => { Promise.resolve(promise).catch(() => {}); };

const server = https.createServer({ ...tls, minVersion: 'TLSv1.2' }, async (req, res) => {
  try {
    const chunks = []; let size = 0;
    for await (const chunk of req) { size += chunk.length; if (size > MAX_BODY) { res.writeHead(413).end(); req.destroy(); return; } chunks.push(chunk); }
    const headers = new Headers();
    for (const [name, value] of Object.entries(req.headers)) if (typeof value === 'string') headers.set(name, value);
    const response = await worker.fetch(new Request('https://service' + req.url, { method: req.method, headers, body: ['GET', 'HEAD'].includes(req.method) ? undefined : Buffer.concat(chunks) }), env, { waitUntil: background });
    res.writeHead(response.status, Object.fromEntries(response.headers)); res.end(Buffer.from(await response.arrayBuffer()));
  } catch { if (!res.headersSent) res.writeHead(500, { 'Content-Type': 'application/json' }); res.end('{"error":"The request could not be completed."}'); }
});
server.requestTimeout = 30000; server.headersTimeout = 15000;
// The housekeeping Cloudflare runs from a cron trigger: old closed cases out, watched addresses refreshed.
const housekeeping = () => worker.scheduled({}, env, { waitUntil: background }).catch(() => {});
setInterval(housekeeping, 15 * 60 * 1000).unref();
server.listen(Number(PORT) || 8443, () => { console.log('Sentinel service listening on port ' + server.address().port + (env.AI?.answer ? ', deciding with ' + env.AI_MODEL + ' in this process' : '') + (env.SENTINEL_MEMORY ? ', remembering verdicts with ' + env.SENTINEL_MEMORY.engine : '')); housekeeping(); });
for (const signal of ['SIGINT', 'SIGTERM']) process.on(signal, () => server.close(() => { env.DB.close(); process.exit(0); }));
