import test from 'node:test';
import assert from 'node:assert/strict';
import { requestLog } from '../src/dev-log.mjs';
import worker, { PROTOCOL } from '../src/service.mjs';
import { environment } from './d1.mjs';

test('diagnostics describe accepted requests without logging credentials or request content', async () => {
  const env = environment({ TOR_EXITS: 'off', WATCHLIST: 'off' }), entries = [];
  async function call(method, url, body, token) {
    const trace = requestLog((event, fields) => entries.push({ event, ...fields }), { method, url }, 'alpha.example');
    const response = await worker.fetch(new Request('https://alpha.example' + url, {
      method, body: body && JSON.stringify(body), headers: token ? { Authorization: 'Bearer ' + token } : {},
    }), env, { waitUntil() {}, diagnostics: trace.details });
    trace.finish(response.status);
    return response.json();
  }

  const enrollment = { protocol: PROTOCOL, platform: 'windows', version: '1.8.1', label: 'claim-in-request' };
  await call('POST', '/v1/enroll?secret=query-value', { ...enrollment, key: 'rejected-key' });
  assert.equal(entries[0].status, 401);
  assert.equal(entries[0].device_id, undefined);
  const device = await call('POST', '/v1/enroll', { ...enrollment, key: env.ENROLL_KEY });
  assert.equal(entries[1].device_id, device.device_id);

  const name = 'Directory account audit-case-name';
  await call('POST', '/v1/report', {
    protocol: PROTOCOL, platform: 'windows', version: '1.8.1',
    mesh: { coverage: { directory_log: true, responds: 'report' } },
    cases: [{ key: 'b'.repeat(32), name, remotes: [], signals: [{ id: 'privileged_group_change', points: 5, evidence: 'private-evidence' }] }],
  }, device.token);
  const { status, cases, saved, signals, directory_log, mode } = entries[2];
  assert.deepEqual({ status, cases, saved, signals, directory_log, mode }, {
    status: 200, cases: 1, saved: 1, signals: ['privileged_group_change'], directory_log: true, mode: 'report',
  });

  const result = await call('GET', '/v1/cases', undefined, env.ADMIN_TOKEN);
  assert.equal(result.cases[0].title, 'Privileged group membership changed: ' + name);
  await call('GET', '/some/unknown-value?dangerous-query', undefined, env.ADMIN_TOKEN);
  assert.equal(entries[4].path, 'unknown');
  const written = JSON.stringify(entries);
  for (const value of [env.ENROLL_KEY, env.ADMIN_TOKEN, device.token, 'query-value', 'rejected-key', 'claim-in-request', name, 'private-evidence', 'unknown-value', 'dangerous-query']) {
    assert.ok(!written.includes(value));
  }
});
