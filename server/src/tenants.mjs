import { lstatSync, realpathSync, statSync } from 'node:fs';
import { basename, dirname, join, resolve } from 'node:path';
import worker from './service.mjs';
import { json } from './util.mjs';

// Several organisations on one service. Each tenant is a whole service of its own: its own database, its own
// enrolment key, operator token and data key, reached under its own host name. Nothing is shared between two
// tenants but the program and the port, so there is no query that could read across them: a machine or an
// operator of one tenant that calls another tenant's name holds no credential that tenant knows.
//
// A tenant is a set of settings, the same ones a single service takes, plus HOST: the name its machines and
// operators call it by.
const SECRETS = ['ENROLL_KEY', 'ADMIN_TOKEN', 'DATA_KEY'];
const hostName = value => typeof value === 'string' && /^(?=.{1,253}$)([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)*$/.test(value);
// The name a request was sent to, as a tenant would be listed: lower case, without the port.
export const hostOf = header => String(header || '').trim().toLowerCase().replace(/:\d{1,5}$/, '').replace(/\.$/, '');

function databasePath(path) {
  if (path === ':memory:') return path;
  const absolute = resolve(path);
  try { return realpathSync.native(absolute); }
  catch (error) {
    // SQLite can create a file, once its parent exists. An unresolved link is a configuration error.
    if (error.code !== 'ENOENT' || lstatSync(absolute, { throwIfNoEntry: false })) throw error;
    return join(realpathSync.native(dirname(absolute)), basename(absolute));
  }
}

// Checks a list of [name, settings] and returns them by host. Throws a sentence saying what is wrong with which
// tenant. Two tenants may not share a host, a database or any secret: a shared secret would let one tenant's
// operator or machines in at the other's name.
export function checkTenants(list) {
  const byHost = new Map(), used = new Map();
  const claim = (what, value, name) => { const key = what + '\n' + value; if (used.has(key)) throw new Error('Tenants ' + used.get(key) + ' and ' + name + ' have the same ' + what + '. Each tenant needs its own.'); used.set(key, name); };
  for (const [name, settings] of list) {
    const host = hostOf(settings.HOST);
    if (!hostName(host)) throw new Error('Tenant ' + name + ' needs HOST: the name its machines call, for example ' + name + '.sentinel.example.org');
    for (const secret of SECRETS) {
      if (typeof settings[secret] !== 'string' || settings[secret].length < 32) throw new Error('Tenant ' + name + ' needs ' + secret + ' (at least 32 characters).');
      // A secret is compared with every secret of every other tenant, whatever its kind.
      claim('secret', settings[secret], name);
    }
    if (settings.INGEST_TOKEN && !SECRETS.some(secret => settings[secret] === settings.INGEST_TOKEN)) {
      claim('secret', settings.INGEST_TOKEN, name);
    }
    if (!settings.DATABASE) throw new Error('Tenant ' + name + ' needs DATABASE: the path of its own database file.');
    const path = databasePath(settings.DATABASE);
    claim('database', process.platform === 'win32' ? path.toLowerCase() : path, name);
    const file = path === ':memory:' ? null : statSync(path, { bigint: true, throwIfNoEntry: false });
    if (file?.ino) claim('database', file.dev + ':' + file.ino, name);
    claim('host', host, name);
    byHost.set(host, { ...settings, HOST: host, DATABASE: path });
  }
  return byHost;
}

// One handler for all tenants. `tenants` is a Map of host -> that tenant's environment (its settings and its DB).
// A name no tenant has is answered as if nothing were there; it is told nothing about which names exist.
export function router(tenants) {
  return {
    async fetch(request, host, ctx) {
      const env = tenants.get(hostOf(host));
      return env ? worker.fetch(request, env, ctx) : json({ error: 'Not found.' }, 404);
    },
    // Housekeeping for each tenant in turn. One tenant's failure does not stop the next one's.
    async scheduled(event, ctx) { for (const env of tenants.values()) { try { await worker.scheduled(event, env, ctx); } catch {} } }
  };
}
