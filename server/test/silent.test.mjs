import test from 'node:test';
import assert from 'node:assert/strict';
import worker, { PROTOCOL, housekeeping, invalidate } from '../src/service.mjs';
import { environment } from './d1.mjs';

const ADMIN = 'a'.repeat(40), KEY = 'e'.repeat(40);
function service(changes) {
  const alerts = [], env = environment({ TOR_EXITS: 'off', WATCHLIST: 'off', ALERT_WEBHOOK_URL: 'https://hooks.example/x', ...changes }), ctx = { waitUntil: promise => { alerts.pending = (alerts.pending || []).concat(promise); } };
  const call = async (method, path, body, token) => {
    const response = await worker.fetch(new Request('https://sentinel.example' + path, { method, headers: { 'Content-Type': 'application/json', ...(token ? { Authorization: 'Bearer ' + token } : {}) }, body: body ? JSON.stringify(body) : undefined }), env, ctx);
    return { status: response.status, body: await response.json() };
  };
  const enrol = async (label, platform = 'windows') => (await call('POST', '/v1/enroll', { protocol: PROTOCOL, key: KEY, platform, version: '0.2.0', label })).body;
  const answer = (device, platform = 'windows') => call('POST', '/v1/report', { protocol: PROTOCOL, version: '0.2.0', platform, cases: [], watching: {} }, device.token);
  const ago = (label, seconds) => env.DB.prepare('UPDATE devices SET last_seen_at=? WHERE label=?').bind(Math.floor(Date.now() / 1000) - seconds, label).run();
  const cases = async () => (await call('GET', '/v1/cases', null, ADMIN)).body.cases;
  const keep = async () => { const done = await housekeeping(env, ctx); await Promise.all(alerts.pending || []); alerts.pending = []; return done; };
  return { env, call, enrol, answer, ago, cases, keep, alerts };
}
// The alert webhook is the only request these tests let out.
const real = globalThis.fetch;
const heard = list => { globalThis.fetch = async (url, options) => { list.push(JSON.parse(options.body)); return new Response('{}'); }; };

test('a machine whose agent stops answering gets a case, once for each silence', async t => {
  const s = service(); heard(s.alerts); t.after(() => { globalThis.fetch = real; });
  const dc = await s.enrol('dc-01'), pc = await s.enrol('desk-07');
  await s.answer(dc); await s.answer(pc);
  assert.deepEqual(await s.keep(), { cases_removed: 0 });            // both answered just now
  await s.ago('dc-01', 16 * 60);
  assert.deepEqual(await s.keep(), { cases_removed: 0, silent_agents: 1 });
  let found = await s.cases();
  assert.deepEqual(found.map(item => [item.device, item.title, item.level, item.severity, item.state]), [['dc-01', 'Agent stopped answering: dc-01', 'SUSPECT', 'high', 'open']]);
  const full = (await s.call('GET', '/v1/cases/' + found[0].id, null, ADMIN)).body;
  assert.match(full.detail.signals[0].evidence, /^Last answered \d{4}-\d\d-\d\d \d\d:\d\d UTC and was not removed from this service\.$/);
  assert.equal(s.alerts.length, 1);
  assert.match(s.alerts[0].text, /^dc-01: its Sentinel agent stopped answering\..*cannot tell which/);
  assert.deepEqual([s.alerts[0].case_id, s.alerts[0].signals], [found[0].id, ['agent_silent']]);
  const reserved = { ...full.detail, signals: [{ id: 'privileged_group_change', points: 5, evidence: 'Fixture audit event.' }] };
  assert.equal((await s.call('POST', '/v1/report', { protocol: PROTOCOL, version: '0.2.0', platform: 'windows', cases: [reserved] }, dc.token)).status, 400);
  // Said once: the next rounds of housekeeping, while it is still silent, add nothing, even after the case is closed.
  assert.deepEqual(await s.keep(), { cases_removed: 0 });
  await s.call('POST', '/v1/cases/' + found[0].id + '/action', { action: 'resolve' }, ADMIN);
  assert.deepEqual(await s.keep(), { cases_removed: 0 });
  assert.equal(s.alerts.length, 1);
  // It answers again, then goes silent again: the same case opens again.
  await s.answer(dc); await s.ago('dc-01', 3600);
  await s.env.DB.prepare('UPDATE cases SET last_seen_at=last_seen_at-7200').run();
  assert.equal((await s.keep()).silent_agents, 1);
  found = await s.cases();
  assert.deepEqual([found.length, found[0].state, s.alerts.length], [1, 'open', 2]);
});

test('overlapping housekeeping passes record and alert on a silence once', async t => {
  const s = service(); heard(s.alerts); t.after(() => { globalThis.fetch = real; });
  const device = await s.enrol('lab-member');
  await s.answer(device);
  await s.ago('lab-member', 1800);
  const passes = await Promise.all([s.keep(), s.keep()]);
  assert.equal(passes.reduce((count, pass) => count + (pass.silent_agents || 0), 0), 1);
  assert.equal((await s.cases()).length, 1);
  assert.equal(s.alerts.length, 1);
  const audit = await s.env.DB.prepare("SELECT COUNT(*) AS n FROM audit WHERE action='agent_silent'").first();
  assert.equal(audit.n, 1);
});

test('retention keeps a resolved silence until the device answers again', async t => {
  const s = service({ CASE_RETENTION_DAYS: '1' }); heard(s.alerts); t.after(() => { globalThis.fetch = real; });
  const device = await s.enrol('lab-member');
  await s.answer(device);
  await s.ago('lab-member', 3 * 86400);
  await s.keep();
  const [silence] = await s.cases();
  await s.call('POST', '/v1/cases/' + silence.id + '/action', { action: 'resolve' }, ADMIN);
  await s.env.DB.prepare('UPDATE cases SET last_seen_at=last_seen_at-? WHERE id=?').bind(2 * 86400, silence.id).run();
  assert.deepEqual(await s.keep(), { cases_removed: 0 });
  assert.equal((await s.cases())[0].state, 'resolved');
  assert.equal(s.alerts.length, 1);
  await s.answer(device);
  assert.deepEqual(await s.keep(), { cases_removed: 1 });
  assert.deepEqual(await s.cases(), []);
});

test('a machine that was removed, never answered, or is called ours when silent raises nothing', async t => {
  const s = service(); heard(s.alerts); t.after(() => { globalThis.fetch = real; });
  const gone = await s.enrol('old-01'), laptop = await s.enrol('laptop-03'); await s.enrol('never-01');
  await s.answer(gone); await s.answer(laptop);
  await s.call('POST', '/v1/devices/' + gone.device_id + '/revoke', null, ADMIN);
  // Stand-in devices for cloud records and edge systems are not machines with an agent.
  await s.env.DB.prepare("INSERT INTO devices(id,label,platform,created_at,last_seen_at) VALUES('c','Cloud audit (entra-audit)','cloud',1,1),('e','Edge (shop)','edge',1,1)").run();
  await s.env.DB.prepare('UPDATE devices SET last_seen_at=last_seen_at-86400 WHERE last_seen_at IS NOT NULL').run();
  assert.equal((await s.keep()).silent_agents, 1);
  const found = await s.cases();
  assert.deepEqual(found.map(item => item.device), ['laptop-03']);
  // "It is ours": a laptop that is often off. Never raised for that machine again.
  await s.call('POST', '/v1/cases/' + found[0].id + '/action', { action: 'trust' }, ADMIN);
  await s.answer(laptop); await s.ago('laptop-03', 86400);
  assert.deepEqual(await s.keep(), { cases_removed: 0 });
  assert.equal(s.alerts.length, 1);
});

test('the silence that counts stretches with the reporting interval, SILENT_CASES=off turns it off, and no agent can report it', async () => {
  // 2 machines at 0.002 writes a second report every 1000 s: quiet for 2500 s is still normal.
  const slow = service({ HEARTBEAT_WRITES_PER_SECOND: '0.002' }), a = await slow.enrol('n1'); await slow.enrol('n2');
  await slow.answer(a); await slow.ago('n1', 2000); invalidate(slow.env);  // the count of machines is kept for a few seconds
  assert.deepEqual(await slow.keep(), { cases_removed: 0 });
  await slow.ago('n1', 2600);
  assert.equal((await slow.keep()).silent_agents, 1);
  const off = service({ SILENT_CASES: 'off' }), b = await off.enrol('n1');
  await off.answer(b); await off.ago('n1', 86400);
  assert.deepEqual(await off.keep(), { cases_removed: 0 });
  const s = service(), c = await s.enrol('n1');
  const forged = { key: 'b'.repeat(32), name: 'dc-01', path: '', parent: '', signals: [{ id: 'agent_silent', points: 5, category: 'coverage', evidence: 'x' }], remotes: [] };
  assert.equal((await s.call('POST', '/v1/report', { protocol: PROTOCOL, version: '0.2.0', platform: 'windows', cases: [forged], watching: {} }, c.token)).status, 400);
});
