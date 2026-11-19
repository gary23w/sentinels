// Run the Sentinel service on your own machine, for good: a database file that survives restarts, HTTPS with
// your own certificate, and the same housekeeping the Cloudflare deployment runs on a timer.
//
//   node serve.mjs /etc/garrett-service/service.conf
//
// The one-line installers (service.sh, service.ps1) write that file and start this for you. Its lines are NAME=value:
//   ENROLL_KEY, ADMIN_TOKEN, DATA_KEY   required, 32+ characters each (see the README)
//   DATABASE                            path of the database file
//   PORT                                default 8443
//   ADDRESS                             the name or address machines call this service by; the installers put it in
//                                       the join command. It does not choose what the service listens on.
//   BIND                                the address to listen on; all interfaces when it is not set
//   TLS_CERT and TLS_KEY                PEM files, or TLS_PFX and TLS_PASSPHRASE
//   MEMORY                              neuron-db to remember verdicts and recall the nearest (see src/memory.mjs); off by
//                                       default. The same on the command line:  node serve.mjs <file> --memory neuron-db
//   MODEL_DIR                           the folder of the decision model that comes with Sentinels (model.onnx and its
//                                       tokenizer): with AI_PROVIDER=decision and no AI_BASE_URL, the service runs it itself,
//                                       in this process. The installer sets this up; it needs the packages the bundles carry.
//   AI_CA_CERT                          a PEM certificate to trust for AI_BASE_URL, when a model of your own has one
//   anything else                       the same settings wrangler.example.jsonc documents (RESPONSE_MODE, FLEET_BLOCK, ...)
//
// Several organisations on one service: put TENANTS=<folder> in that file. Every <name>.conf in the folder is one
// tenant, with HOST (the name its machines call), its own ENROLL_KEY, ADMIN_TOKEN, DATA_KEY and DATABASE, and any
// of the other settings. A request is answered by the tenant whose HOST it was sent to and by no other; the keys
// and the database in the main file are then not used. The certificate must be good for every tenant's name.
// MEMORY and MODEL_DIR in the main file are the defaults for each tenant; either one in a tenant file overrides it
// for that tenant. AI_CA_CERT is trusted by the whole process, so it is read from the main file only.
// Needs Node.js 22.13 or newer. No packages to install, unless MEMORY is set: then run "npm install" in this folder.
//
// LOG=on enables JSON Lines diagnostics on standard error; LOG=<file> also appends to a file.
// SENTINEL_LOG supplies the default if LOG is omitted.
import https from 'node:https';
import { getCACertificates, setDefaultCACertificates } from 'node:tls';
import { readFileSync, readdirSync } from 'node:fs';
import { join } from 'node:path';
import worker from './src/worker.mjs';
import { database } from './sqlite.mjs';
import { memoryChoice, neuronMemory } from './src/memory.mjs';
import { checkTenants, router, hostOf } from './src/tenants.mjs';
import { housekeeping } from './src/service.mjs';
import { createDevLog, errorCode, requestLog } from './src/dev-log.mjs';

const MAX_BODY = 1024 * 1024;
const file = process.argv[2];
if (!file) { console.error('Usage: node serve.mjs <configuration file>'); process.exit(1); }
const read = path => { const found = {}; for (const line of readFileSync(path, 'utf8').split(/\r?\n/)) { const pair = /^([A-Z][A-Z0-9_]*)=(.*)$/.exec(line.trim()); if (pair) found[pair[1]] = pair[2]; } return found; };
const settings = read(file);
if (!settings.TENANTS) {
  for (const name of ['ENROLL_KEY', 'ADMIN_TOKEN', 'DATA_KEY']) if (!settings[name] || settings[name].length < 32) { console.error(name + ' must be set in ' + file + ' (at least 32 characters).'); process.exit(1); }
  if (!settings.DATABASE) { console.error('DATABASE must be set in ' + file + '.'); process.exit(1); }
}
const tls = settings.TLS_PFX ? { pfx: readFileSync(settings.TLS_PFX), passphrase: settings.TLS_PASSPHRASE || '' }
  : settings.TLS_CERT && settings.TLS_KEY ? { cert: readFileSync(settings.TLS_CERT), key: readFileSync(settings.TLS_KEY) } : null;
if (!tls) { console.error('Set TLS_CERT and TLS_KEY, or TLS_PFX, in ' + file + '. Agents only talk to a service over HTTPS.'); process.exit(1); }

const { PORT, DATABASE, TLS_CERT, TLS_KEY, TLS_PFX, TLS_PASSPHRASE, ADDRESS, BIND, TENANTS, MEMORY, LOG, AI_CA_CERT, MODEL_DIR, ...rest } = settings;
if (AI_CA_CERT) {
  if (typeof setDefaultCACertificates !== 'function') { console.error('This Node.js cannot be given an extra certificate for AI_CA_CERT. Start it with NODE_EXTRA_CA_CERTS=' + AI_CA_CERT + ' instead, or use a newer Node.js.'); process.exit(1); }
  try { setDefaultCACertificates([...getCACertificates('default'), readFileSync(AI_CA_CERT, 'utf8')]); } catch (error) { console.error('AI_CA_CERT could not be read: ' + error.message); process.exit(1); }
}
const log = createDevLog(LOG ?? process.env.SENTINEL_LOG);
const environments = new Map();
// A decision model is loaded once for each folder, and shared by the tenants that name it.
const models = new Map();
try {
  const configs = TENANTS
    ? checkTenants(readdirSync(TENANTS).filter(name => name.endsWith('.conf')).sort().map(name => [name.slice(0, -5), read(join(TENANTS, name))]))
    : new Map([[null, { ...rest, DATABASE }]]);
  if (!configs.size) throw new Error('No tenant was found in ' + TENANTS + '. Put one <name>.conf there for each.');
  for (const [host, { DATABASE: path, HOST, MEMORY: memorySetting, MODEL_DIR: modelSetting, ...own }] of configs) {
    const memory = memoryChoice(memorySetting ?? MEMORY, process.argv.slice(3));
    const env = { AI_PROVIDER: 'none', ...own, DB: database(path) };
    environments.set(host, env);
    if (memory) env.SENTINEL_MEMORY = await neuronMemory(env);
    const folder = modelSetting ?? MODEL_DIR;
    if (folder && env.AI_PROVIDER === 'decision' && !env.AI_BASE_URL) {
      try {
        if (!models.has(folder)) models.set(folder, await (await import('./src/decisions.mjs')).localModel(folder));
        env.AI = models.get(folder);
        if (!env.AI_MODEL) env.AI_MODEL = env.AI.name;
      } catch (error) { throw new Error('The decision model in ' + folder + ' could not be loaded: ' + error.message); }
    }
  }
} catch (error) {
  for (const env of environments.values()) env.DB.close();
  console.error(error.message);
  process.exit(1);
}
const many = TENANTS ? router(environments) : null;
const single = environments.get(null);
const background = tenant => promise => {
  Promise.resolve(promise).catch(error => log?.('background_error', { tenant, error: errorCode(error) }));
};

const server = https.createServer({ ...tls, minVersion: 'TLSv1.2' }, async (req, res) => {
  const host = hostOf(req.headers.host), tenant = environments.has(host) ? host : null;
  const trace = requestLog(log, req, tenant);
  let status = 500;
  try {
    const chunks = []; let size = 0;
    for await (const chunk of req) {
      size += chunk.length;
      if (size > MAX_BODY) { status = 413; res.writeHead(status).end(); req.destroy(); return; }
      chunks.push(chunk);
    }
    const headers = new Headers();
    for (const [name, value] of Object.entries(req.headers)) if (typeof value === 'string') headers.set(name, value);
    const request = new Request('https://service' + req.url, { method: req.method, headers, body: ['GET', 'HEAD'].includes(req.method) ? undefined : Buffer.concat(chunks) });
    const ctx = { waitUntil: background(tenant), diagnostics: trace?.details };
    const response = many ? await many.fetch(request, req.headers.host, ctx) : await worker.fetch(request, single, ctx);
    const out = Buffer.from(await response.arrayBuffer());
    status = response.status;
    res.writeHead(status, Object.fromEntries(response.headers)); res.end(out);
  } catch (error) {
    if (!res.headersSent) { status = 500; res.writeHead(status, { 'Content-Type': 'application/json' }); }
    res.end('{"error":"The request could not be completed."}');
    if (trace) trace.details.error = errorCode(error);
  } finally {
    trace?.finish(status);
  }
});
if (log) server.on('tlsClientError', error => log('tls_error', { error: errorCode(error) }));
server.requestTimeout = 30000; server.headersTimeout = 15000;
// The housekeeping Cloudflare runs from a cron trigger: old closed cases out, watched addresses refreshed.
const sweep = async () => {
  for (const [tenant, env] of environments) {
    try { const done = await housekeeping(env, { waitUntil: background(tenant) }); log?.('housekeeping', { tenant, ...done }); }
    catch (error) { log?.('housekeeping_error', { tenant, error: errorCode(error) }); }
  }
};
setInterval(sweep, 15 * 60 * 1000).unref();
server.listen(Number(PORT) || 8443, BIND || undefined, () => {
  const hosts = many ? [...environments.keys()] : null;
  const deciding = [...environments.values()].find(env => env.AI?.answer);
  const memory = single?.SENTINEL_MEMORY;
  console.log('Sentinel service listening on port ' + server.address().port + (hosts ? ' for ' + hosts.join(', ') : '') + (deciding ? ', deciding with ' + deciding.AI_MODEL + ' in this process' : '') + (memory ? ', remembering verdicts with ' + memory.engine : ''));
  log?.('listening', { port: server.address().port, tenants: hosts });
  sweep();
});
for (const signal of ['SIGINT', 'SIGTERM']) process.on(signal, () => server.close(() => {
  for (const env of environments.values()) env.DB.close();
  process.exit(0);
}));
