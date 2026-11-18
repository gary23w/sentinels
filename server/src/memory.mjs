import { now, seal, unseal } from './util.mjs';

// An optional recall memory for the verdicts operators gave, kept by neuron-db (github.com/gary23w/neuron-db, MIT).
//
// It is off unless asked for: MEMORY=neuron-db in the service's configuration file, or --memory neuron-db on the
// command line of serve.mjs or local.mjs. Turned on, every verdict is remembered as one sentence (the verdict, the
// platform, the signal ids: the same SHAPE learning.mjs keeps, never a name, a path, an address or a command
// line), and a new case is shown the remembered verdicts nearest to it: to the operator, and to the analyst
// model if one is configured. It is advice only. Nothing recalled changes a score, a weight or a command.
//
// neuron-db is used as published, through its own package: "npm install" in this folder brings in the newest
// release. Two things it does not do are done here. It matches words by their stem, so boot_entry_added and
// boot_entry_removed look alike to it: a recalled sentence counts only if it holds at least half of the case's
// signal ids, whole. And it keeps a repeated sentence once per repeat: repeats are counted here and kept once.
//
// The sentences are stored sealed with DATA_KEY in the memory table, and the engine is filled from them at start.
export const MEMORY_ENGINES = ['neuron-db'];
const SCOPE = 'verdicts', NEEDS = ['observe', 'obsmany', 'recallscored', 'forget'];

const clean = text => String(text ?? '').toLowerCase().replace(/[^a-z0-9_ ]+/g, ' ').replace(/ +/g, ' ').trim().slice(0, 400);

// The setting, from the configuration file or the command line ("--memory neuron-db" or "--memory=neuron-db").
export function memoryChoice(setting, argv = []) {
  const at = argv.findIndex(item => item === '--memory' || item.startsWith('--memory='));
  const asked = at < 0 ? setting : argv[at].includes('=') ? argv[at].slice(9) : argv[at + 1];
  const choice = String(asked ?? '').trim().toLowerCase();
  if (!choice || choice === 'off' || choice === 'none') return null;
  if (!MEMORY_ENGINES.includes(choice)) throw new Error('Unknown memory "' + choice + '". Choose one of: ' + MEMORY_ENGINES.join(', ') + ', or off.');
  return choice;
}

async function engine() {
  let binding;
  try { binding = await import('@gary23w/neuron-db'); } catch { throw new Error('The neuron-db memory was asked for, but its package is not installed. Run "npm install" in the service folder.'); }
  const { fileURLToPath } = await import('node:url');
  const db = await binding.NeuronDB.forNode(fileURLToPath(import.meta.resolve('@gary23w/neuron-db/neuron_core.wasm')));
  const missing = NEEDS.filter(op => !db.supports(op));
  if (missing.length) throw new Error('This neuron-db release (' + binding.VERSION + ') has no ' + missing.join(', ') + '. The memory cannot run on it.');
  return db;
}

// The object learning.mjs looks for as env.SENTINEL_MEMORY: { remember, recall, forget, count }.
export async function neuronMemory(env, MEMORY_MAX = 5000) {
  const db = await engine();
  let known = new Map();  // sentence -> how many times it was remembered, oldest first
  try {
    const row = await env.DB.prepare('SELECT facts FROM memory WHERE id=1').first();
    const kept = [];
    for (const part of JSON.parse(row?.facts || '[]')) kept.push(...await unseal(part, env.DATA_KEY));
    for (const [fact, times] of kept.slice(-MEMORY_MAX)) if (typeof fact === 'string' && clean(fact) === fact && fact && Number.isSafeInteger(times) && times > 0) known.set(fact, times);
  } catch {}
  const fill = () => { db.forget(SCOPE); db.observeMany(SCOPE, [...known.keys()]); };
  // Sealed a hundred sentences at a time: seal() takes values of a few tens of kilobytes.
  const save = async () => {
    const all = [...known], parts = [];
    for (let at = 0; at < all.length; at += 100) parts.push(await seal(all.slice(at, at + 100), env.DATA_KEY));
    await env.DB.prepare('INSERT INTO memory(id,facts,updated_at) VALUES(1,?,?) ON CONFLICT(id) DO UPDATE SET facts=excluded.facts,updated_at=excluded.updated_at').bind(JSON.stringify(parts), now()).run();
  };
  fill();
  return {
    engine: 'neuron-db',
    count: () => known.size,
    async remember(text) {
      const fact = clean(text);
      if (!fact) return;
      const times = known.get(fact) || 0;
      known.delete(fact); known.set(fact, times + 1);  // the latest verdict is the last one dropped
      if (known.size > MEMORY_MAX) { known = new Map([...known].slice(-MEMORY_MAX)); fill(); } else if (!times) db.observe(SCOPE, fact);
      await save();
    },
    // The remembered sentences nearest to `text`, best first. `about` is { platform, shape } when the caller has them.
    async recall(text, most = 3, about = {}) {
      const query = clean(text), ids = (Array.isArray(about.shape) && about.shape.length ? about.shape : query.split(' ')).map(clean).filter(Boolean);
      if (!query || !ids.length) return [];
      const need = Math.ceil(ids.length / 2), platform = clean(about.platform), found = new Map();
      for (const hit of db.recallScored(SCOPE, query, 24)) {
        if (!known.has(hit.fact) || found.has(hit.fact)) continue;
        const words = new Set(hit.fact.split(' ')), shared = ids.filter(id => words.has(id)).length;
        if (shared >= need) found.set(hit.fact, { fact: hit.fact, shared, same: platform && words.has(platform) ? 1 : 0, times: known.get(hit.fact) });
      }
      // Nearest first: most of the case's signals, this platform, the fewest signals of its own, the most often said.
      return [...found.values()].sort((a, b) => b.shared - a.shared || b.same - a.same || a.fact.split(' ').length - b.fact.split(' ').length || b.times - a.times).slice(0, most)
        .map(entry => entry.fact + (entry.times > 1 ? ' (' + entry.times + ' times)' : ''));
    },
    async forget() { known.clear(); db.forget(SCOPE); await env.DB.prepare('DELETE FROM memory WHERE id=1').run(); }
  };
}
