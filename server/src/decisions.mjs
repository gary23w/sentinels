// The decision model that comes with Sentinels (crivo-sentinel-v1), run inside the service: no Python, no
// second program, nothing on the network. The model folder holds model.onnx, tokenizer.json,
// tokenizer_config.json and config.json, as the model repository publishes them.
//
// The question is rendered exactly as the model's own code renders it (model.py in that repository):
//   [CLS] instructions [SEP] state [SEP] [OPT] answer_1 [OPT] answer_2 ... [OPT] answer_n
// with the state as compact JSON with sorted keys, one score read at each [OPT], softmax over the answers.
// localModel() returns what serve.mjs binds as AI: { run(model, input) } answering {"<question>": {"type",
// "choice", "probabilities"}}, the shape analyst.mjs reads.
import { readFileSync } from 'node:fs';
import { join } from 'node:path';

const QUESTION_TYPES = { noul: 0, choice: 1, score: 2 };

// Python's json.dumps(sort_keys=True, separators=(",", ":"), ensure_ascii=False).
export function compact(value) {
  if (value === null || value === undefined) return 'null';
  if (Array.isArray(value)) return '[' + value.map(compact).join(',') + ']';
  if (typeof value === 'object') return '{' + Object.keys(value).sort().map(key => JSON.stringify(key) + ':' + compact(value[key])).join(',') + '}';
  return JSON.stringify(value);
}
export function render(content) {
  if (content === null || content === undefined) return '';
  if (typeof content === 'string') return content.trim();
  return compact(content);
}
// The answers of a choice question, as texts, with their keys.
export function optionTexts(criteria) {
  const keys = Object.keys(criteria);
  return { keys, texts: keys.map(key => { const text = render(criteria[key]); return text && text !== key ? key + ': ' + text : key; }) };
}

export async function localModel(folder) {
  const { Tokenizer } = await import('@huggingface/tokenizers');
  const ort = await import('onnxruntime-node');
  const read = name => JSON.parse(readFileSync(join(folder, name), 'utf8'));
  const tokenizer = new Tokenizer(read('tokenizer.json'), read('tokenizer_config.json'));
  const config = read('config.json');
  const ids = { cls: tokenizer.token_to_id('[CLS]'), sep: tokenizer.token_to_id('[SEP]'), pad: tokenizer.token_to_id('[PAD]'), opt: config.decision?.opt_token_id ?? tokenizer.token_to_id('[OPT]') };
  for (const [name, id] of Object.entries(ids)) if (typeof id !== 'number') throw new Error('The model tokenizer has no ' + name + ' token.');
  const session = await ort.InferenceSession.create(join(folder, 'model.onnx'), { executionProviders: ['cpu'], graphOptimizationLevel: 'all' });
  const tokens = text => text ? tokenizer.encode(text, { add_special_tokens: false }).ids : [];

  function encode(instructions, state, options) {
    const sequence = [ids.cls, ...tokens(render(instructions)), ids.sep, ...tokens(render(state)), ids.sep];
    const positions = [];
    for (const option of options) { positions.push(sequence.length); sequence.push(ids.opt, ...tokens(option)); }
    return { sequence, positions };
  }
  async function scores(sequence, positions, qtype) {
    const length = Math.ceil(sequence.length / 16) * 16;
    const input = new BigInt64Array(length).fill(BigInt(ids.pad)), mask = new BigInt64Array(length);
    sequence.forEach((id, index) => { input[index] = BigInt(id); mask[index] = 1n; });
    const feed = {
      input_ids: new ort.Tensor('int64', input, [1, length]), attention_mask: new ort.Tensor('int64', mask, [1, length]),
      opt_positions: new ort.Tensor('int64', BigInt64Array.from(positions.map(BigInt)), [1, positions.length]), qtype: new ort.Tensor('int64', BigInt64Array.from([BigInt(qtype)]), [1]),
    };
    const out = await session.run(feed);
    return Array.from(out.logits.data);
  }
  async function answer(state, questions) {
    const result = {};
    for (const [key, question] of Object.entries(questions || {})) {
      if (!question || question.type !== 'choice' || !question.criteria || typeof question.criteria !== 'object') throw new Error('The question ' + key + ' is not a choice with criteria.');
      const { keys, texts } = optionTexts(question.criteria);
      if (!keys.length) throw new Error('The question ' + key + ' has no answers.');
      const { sequence, positions } = encode(question.instructions, state, texts);
      const logits = await scores(sequence, positions, QUESTION_TYPES.choice);
      const top = Math.max(...logits), weights = logits.map(value => Math.exp(value - top)), total = weights.reduce((sum, value) => sum + value, 0);
      const probabilities = Object.fromEntries(keys.map((name, index) => [name, weights[index] / total]));
      result[key] = { type: 'choice', choice: keys[logits.indexOf(top)], probabilities };
    }
    return result;
  }
  return { name: config.decision?.name || 'crivo-sentinel-v1', tokens: text => tokens(text).length, answer, run: async (model, input) => answer(input?.state, input?.questions) };
}
