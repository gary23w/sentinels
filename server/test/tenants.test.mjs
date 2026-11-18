import test from 'node:test';
import assert from 'node:assert/strict';
import { linkSync, mkdtempSync, rmdirSync, unlinkSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { PROTOCOL } from '../src/service.mjs';
import { SIGNALS } from '../src/signals.mjs';
import { checkTenants, hostOf, router } from '../src/tenants.mjs';
import { database } from './d1.mjs';

const ATTACKER = '203.0.113.50';
const tenant = (letter, host) => ({ HOST: host, ENROLL_KEY: (letter + 'e').repeat(20), ADMIN_TOKEN: (letter + 'a').repeat(20), DATA_KEY: (letter + 'd').repeat(20), DATABASE: letter + '.db', TOR_EXITS: 'off', WATCHLIST: 'off' });
const ALPHA = tenant('1', 'alpha.sentinel.example'), BRAVO = tenant('2', 'bravo.sentinel.example');
function service(alpha = ALPHA, bravo = BRAVO) {
  const found = checkTenants([['alpha', alpha], ['bravo', bravo]]);
  const many = router(new Map([...found].map(([host, { DATABASE, HOST, ...own }]) => [host, { ...own, DB: database() }]))), ctx = { waitUntil: () => {} };
  const call = async (host, method, path, body, token) => {
    const response = await many.fetch(new Request('https://service' + path, { method, headers: { 'Content-Type': 'application/json', ...(token ? { Authorization: 'Bearer ' + token } : {}) }, body: body ? JSON.stringify(body) : undefined }), host, ctx);
    return { status: response.status, body: await response.json() };
  };
  const enrol = async (who, label) => (await call(who.HOST, 'POST', '/v1/enroll', { protocol: PROTOCOL, key: who.ENROLL_KEY, platform: 'linux', version: '0.2.0', label })).body;
  return { call, enrol, many };
}
const signal = id => ({ id, points: SIGNALS[id].weight, category: 'x', evidence: 'Written on the device.' });
const report = cases => ({ protocol: PROTOCOL, version: '0.2.0', platform: 'linux', cases, watching: {} });
const implant = { key: 'a'.repeat(32), name: '.kworkerd', path: '/tmp/.x/.kworkerd', parent: 'systemd', signals: ['runs_from_temp', 'unusual_port', 'beaconing'].map(signal),
  remotes: [{ address: ATTACKER, port: 56001, names: [], direction: 'out' }], actions: [{ action: 'stopped', programs: 1, reason: 'hostile' }] };

test('a request is answered by the tenant it was sent to, and a name no tenant has finds nothing', async () => {
  const s = service();
  for (const host of ['alpha.sentinel.example', 'ALPHA.sentinel.example:8443', 'alpha.sentinel.example.']) assert.equal((await s.call(host, 'GET', '/health')).status, 200);
  for (const host of ['charlie.sentinel.example', 'sentinel.example', 'xalpha.sentinel.example', '', undefined, '127.0.0.1:8443']) assert.deepEqual(await s.call(host, 'GET', '/health'), { status: 404, body: { error: 'Not found.' } });
  assert.deepEqual([hostOf('Alpha.Example:443'), hostOf(' a.b. '), hostOf(undefined)], ['alpha.example', 'a.b', '']);
});

test("one tenant's keys, machines and operator open nothing at another tenant's name", async () => {
  const s = service(), a = await s.enrol(ALPHA, 'web-01');
  assert.match(a.token, /^[a-f0-9]{64}$/);
  // The enrolment key.
  assert.equal((await s.call(BRAVO.HOST, 'POST', '/v1/enroll', { protocol: PROTOCOL, key: ALPHA.ENROLL_KEY, platform: 'linux', version: '0.2.0', label: 'web-01' })).status, 401);
  // A machine's credential and the fleet read key it was given.
  assert.equal((await s.call(BRAVO.HOST, 'POST', '/v1/report', report([]), a.token)).status, 401);
  assert.equal((await s.call(BRAVO.HOST, 'GET', '/v1/state', null, a.state_key)).status, 401);
  assert.equal((await s.call(ALPHA.HOST, 'GET', '/v1/state', null, a.state_key)).status, 200);
  // The operator token, on every operator path.
  for (const [method, path] of [['GET', '/v1/devices'], ['GET', '/v1/cases'], ['GET', '/v1/coverage'], ['GET', '/v1/fleet'], ['GET', '/v1/learning'], ['POST', '/v1/fleet/add'], ['POST', '/v1/cloud-events'], ['GET', '/v1/edge/refused']])
    assert.equal((await s.call(BRAVO.HOST, method, path, method === 'POST' ? { address: ATTACKER } : null, ALPHA.ADMIN_TOKEN)).status, 401, path);
  assert.equal((await s.call(ALPHA.HOST, 'GET', '/v1/devices', null, ALPHA.ADMIN_TOKEN)).body.enrolled, 1);
  assert.equal((await s.call(BRAVO.HOST, 'GET', '/v1/devices', null, BRAVO.ADMIN_TOKEN)).body.enrolled, 0);
});

test('an attack in one tenant leaves no case, no shared address and no change of state in another', async () => {
  const s = service(), a = await s.enrol(ALPHA, 'web-01'), b = await s.enrol(BRAVO, 'web-01');
  const before = (await s.call(BRAVO.HOST, 'GET', '/v1/pulse')).body.revision;
  assert.equal((await s.call(ALPHA.HOST, 'POST', '/v1/report', report([implant]), a.token)).body.saved, 1);
  const own = (await s.call(ALPHA.HOST, 'GET', '/v1/cases', null, ALPHA.ADMIN_TOKEN)).body.cases;
  assert.equal(own.length, 1);
  assert.deepEqual((await s.call(ALPHA.HOST, 'GET', '/v1/fleet', null, ALPHA.ADMIN_TOKEN)).body.indicators.map(row => row.address), [ATTACKER]);
  // Bravo: nothing arrived, by any road.
  assert.deepEqual((await s.call(BRAVO.HOST, 'GET', '/v1/cases', null, BRAVO.ADMIN_TOKEN)).body.cases, []);
  assert.deepEqual((await s.call(BRAVO.HOST, 'GET', '/v1/fleet', null, BRAVO.ADMIN_TOKEN)).body.indicators, []);
  assert.deepEqual((await s.call(BRAVO.HOST, 'POST', '/v1/report', report([]), b.token)).body.fleet, { indicators: {}, suspects: [] });
  assert.equal((await s.call(BRAVO.HOST, 'GET', '/v1/pulse')).body.revision, before);
  // Alpha's case cannot be read or acted on under Bravo's name, even by Bravo's own operator.
  assert.equal((await s.call(BRAVO.HOST, 'GET', '/v1/cases/' + own[0].id, null, BRAVO.ADMIN_TOKEN)).status, 404);
  assert.equal((await s.call(BRAVO.HOST, 'POST', '/v1/cases/' + own[0].id + '/action', { action: 'trust' }, BRAVO.ADMIN_TOKEN)).status, 404);
  assert.equal((await s.call(ALPHA.HOST, 'GET', '/v1/cases/' + own[0].id, null, ALPHA.ADMIN_TOKEN)).body.state, 'open');
  // The two tenants hand their machines different read keys.
  assert.notEqual(a.state_key, b.state_key);
});

test('two tenants may not share a host, a database or any secret, and each needs all of its own', () => {
  const wrong = (changes, said) => assert.throws(() => checkTenants([['alpha', ALPHA], ['bravo', { ...BRAVO, ...changes }]]), said);
  wrong({ HOST: 'ALPHA.sentinel.example:8443' }, /same host/);
  wrong({ DATABASE: ALPHA.DATABASE }, /same database/);
  wrong({ DATABASE: './' + ALPHA.DATABASE }, /same database/);
  wrong({ ADMIN_TOKEN: ALPHA.ADMIN_TOKEN }, /same secret/);
  wrong({ ENROLL_KEY: ALPHA.DATA_KEY }, /same secret/);
  wrong({ INGEST_TOKEN: ALPHA.ADMIN_TOKEN }, /same secret/);
  wrong({ DATA_KEY: 'short' }, /bravo needs DATA_KEY/);
  wrong({ DATABASE: '' }, /bravo needs DATABASE/);
  for (const host of ['', 'not a host', 'under_score.example', '-a.example', undefined]) wrong({ HOST: host }, /bravo needs HOST/);
  assert.deepEqual([...checkTenants([['alpha', ALPHA], ['bravo', BRAVO]]).keys()], [ALPHA.HOST, BRAVO.HOST]);
});

test('tenant database paths must identify separate files', () => {
  const folder = mkdtempSync(join(tmpdir(), 'sentinel-tenant-test-'));
  const databasePath = join(folder, 'alpha.db'), secondPath = join(folder, 'bravo.db');
  try {
    writeFileSync(databasePath, '');
    linkSync(databasePath, secondPath);
    assert.throws(() => checkTenants([
      ['alpha', { ...ALPHA, DATABASE: databasePath }],
      ['bravo', { ...BRAVO, DATABASE: secondPath }],
    ]), /same database/);
  } finally {
    for (const path of [secondPath, databasePath]) {
      try { unlinkSync(path); } catch (error) { if (error.code !== 'ENOENT') throw error; }
    }
    rmdirSync(folder);
  }
});

test('housekeeping runs for every tenant, and one that fails does not stop the next', async () => {
  const s = service(), ran = [];
  const broken = { DB: { prepare() { ran.push('broken'); throw new Error('gone'); } } }, fine = { ...BRAVO, DB: database(), TOR_EXITS: 'off', WATCHLIST: 'off' };
  const prepare = fine.DB.prepare; fine.DB.prepare = text => { ran.push('fine'); return prepare(text); };
  await router(new Map([['a.example', broken], ['b.example', fine]])).scheduled({}, { waitUntil: () => {} });
  assert.ok(ran.includes('broken') && ran.includes('fine'));
  await s.many.scheduled({}, { waitUntil: () => {} });
});

test('each tenant receives only its own watch and Tor feeds', async t => {
  const settings = (tenant, name) => ({
    ...tenant, WATCHLIST: 'on', TOR_EXITS: 'on',
    WATCH_RESOLVER: 'https://' + name + '.feeds.example/dns', TOR_EXIT_LIST: 'https://' + name + '.feeds.example/tor',
  });
  const s = service(settings(ALPHA, 'alpha'), settings(BRAVO, 'bravo'));
  const realFetch = globalThis.fetch;
  t.after(() => { globalThis.fetch = realFetch; });
  globalThis.fetch = async input => {
    const url = new URL(input), address = url.hostname === 'alpha.feeds.example' ? '203.0.113.90' : '203.0.113.91';
    if (url.pathname === '/tor') return new Response(address);
    if (url.searchParams.get('name') === 'webhook.site') return Response.json({ Answer: [{ type: 1, data: address }] });
    return Response.json({ Answer: [] });
  };
  const a = await s.enrol(ALPHA, 'alpha-one'), b = await s.enrol(BRAVO, 'bravo-one');
  await s.many.scheduled({}, { waitUntil: () => {} });
  for (const [tenant, device, address] of [[ALPHA, a, '203.0.113.90'], [BRAVO, b, '203.0.113.91']]) {
    const state = await s.call(tenant.HOST, 'GET', '/v1/state', null, device.state_key);
    assert.deepEqual(state.body.watch, { [address]: 'webhook.site' });
    const heartbeat = await s.call(tenant.HOST, 'POST', '/v1/report', report([]), device.token);
    assert.deepEqual(heartbeat.body.exits.addresses, [address]);
  }
});
