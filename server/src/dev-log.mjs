import { appendFileSync } from 'node:fs';

const paths = new Set([
  '/health', '/v1/enroll', '/v1/report', '/v1/pulse', '/v1/state', '/v1/devices', '/v1/cases',
  '/v1/coverage', '/v1/fleet', '/v1/fleet/add', '/v1/fleet/remove', '/v1/learning', '/v1/learning/reset',
  '/v1/cloud-events', '/v1/edge-events', '/v1/edge/refused',
]);
const methods = new Set(['GET', 'POST', 'PUT', 'PATCH', 'DELETE', 'HEAD', 'OPTIONS']);

function routeOf(url) {
  const path = url.split('?', 1)[0];
  if (paths.has(path)) return path;
  if (/^\/v1\/devices\/[0-9a-f-]{36}\/revoke$/.test(path)) return '/v1/devices/:id/revoke';
  const match = /^\/v1\/cases\/[0-9a-f-]{36}(\/(?:action|analyze))?$/.exec(path);
  return match ? '/v1/cases/:id' + (match[1] || '') : 'unknown';
}

export function createDevLog(target) {
  if (!target || target === 'off') return null;
  const file = target === 'on' ? null : target;
  let warned = false;
  return (event, fields) => {
    const line = JSON.stringify({ at: new Date().toISOString(), event, ...fields }) + '\n';
    process.stderr.write(line);
    if (file) {
      try { appendFileSync(file, line, { mode: 0o600 }); }
      catch {
        if (!warned) console.error('Could not append the configured Sentinel development log. Logging to standard error continues.');
        warned = true;
      }
    }
  };
}

export function requestLog(log, request, tenant = null) {
  if (!log) return null;
  const started = performance.now(), path = routeOf(request.url);
  const method = methods.has(request.method) ? request.method : 'other';
  const details = {};
  return {
    details,
    finish(status) { log('request', { tenant, method, path, status, ms: Math.round(performance.now() - started), ...details }); },
  };
}

export function errorCode(error) {
  return typeof error?.code === 'string' && /^[A-Z][A-Z0-9_]{1,63}$/.test(error.code) ? error.code : 'unexpected';
}
