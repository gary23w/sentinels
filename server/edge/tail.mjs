// A sentinel for Cloudflare Workers. A Worker cannot run the agent: there is no process to watch. This small
// Worker is attached to the Workers you want watched and is handed every request they served, after they
// answered, so it adds nothing to their response time. It marks what each request is a sign of (edge.mjs) and
// sends the marks, never the request, to your Sentinel service.
//
// Deploy it once (wrangler.example.jsonc in this folder), then name it in each watched Worker's configuration:
//
//   "tail_consumers": [{ "service": "garrett-edge" }]
//
// Settings:  SENTINEL_URL    your service's address
//            SENTINEL_TOKEN  its INGEST_TOKEN (a secret)
//            SENTINEL_NAME   optional: the name these Workers appear under (default: the Worker's own name)
//
// Cloudflare hands a tail Worker the request's address, method, headers and the status of the answer, and by
// default blanks the address's query and the headers that look like secrets. The marks need the full address, so
// it is read here, in your own account, and stays here.
import { markOf } from '../src/edge.mjs';

// The forwarder's own call to the service, and the guard's. When the service is on a Worker that is itself
// watched, those calls are requests that Worker served: marking them would send a record about every record,
// without end. Every other request to that Worker is still marked.
const OWN = ['/v1/edge-events', '/v1/edge/refused'];
function ownCalls(service) {
  try { const home = new URL(String(service)), base = home.pathname.replace(/\/$/, ''); return OWN.map(path => home.host + base + path); } catch { return []; }
}

// What to send for these events: one record for each request that is a sign of something. `service` is the
// Sentinel service's address, where there is one: the calls made to it from here are left out.
export function recordsOf(events, service = '') {
  const records = [], own = service ? ownCalls(service) : [];
  for (const item of Array.isArray(events) ? events : []) {
    const seen = item?.event?.request, status = item?.event?.response?.status;
    if (!seen || !Number.isInteger(status)) continue;
    const request = typeof seen.getUnredacted === 'function' ? seen.getUnredacted() : seen;
    const headers = request.headers || {};
    const client = headers['cf-connecting-ip'] || headers['CF-Connecting-IP'];
    if (typeof client !== 'string') continue;
    let target;
    try { const url = new URL(request.url); if (own.includes(url.host + url.pathname)) continue; target = url.pathname + url.search; } catch { continue; }
    const marks = markOf(String(request.method || 'GET').toUpperCase(), target, status, headers.cookie || headers.Cookie || '');
    if (marks) records.push({ client, at: Math.floor((Number(item.eventTimestamp) || Date.now()) / 1000), ...marks });
  }
  return records;
}

export default {
  async tail(events, env, ctx) {
    const records = recordsOf(events, env.SENTINEL_URL);
    if (!records.length || !env.SENTINEL_URL || !env.SENTINEL_TOKEN) return;
    const name = String(env.SENTINEL_NAME || events[0]?.scriptName || 'workers').replace(/[^A-Za-z0-9 ._-]/g, '-').slice(0, 40);
    ctx.waitUntil(fetch(String(env.SENTINEL_URL).replace(/\/$/, '') + '/v1/edge-events', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: 'Bearer ' + env.SENTINEL_TOKEN },
      body: JSON.stringify({ name, records: records.slice(0, 1000) })
    }).catch(() => {}));
  }
};
