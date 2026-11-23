// Records golden fixtures from the original FitnessTrack JavaScript so the
// Swift port can be checked against it call-for-call.
//
//   node tools/record-fixtures.mjs /path/to/FitnessTrack
//
// Every call the upstream unit tests make to the pure functions (plus a
// seeded fuzz corpus) is captured with its result and written to
// FitnessTrackTests/Fixtures/*.json.
import { cpSync, mkdtempSync, readFileSync, writeFileSync, appendFileSync, existsSync, mkdirSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const src = process.argv[2];
if (!src || !existsSync(join(src, 'shared/algorithm.js'))) { console.error('usage: record-fixtures.mjs <FitnessTrack checkout>'); process.exit(1); }
const outDir = join(dirname(fileURLToPath(import.meta.url)), '../FitnessTrackTests/Fixtures');
const work = mkdtempSync(join(tmpdir(), 'ft-fixtures-'));
const log = join(work, 'calls.jsonl');
writeFileSync(log, '');

const modules = {
  'shared/algorithm.js': ['nextExerciseTargets', 'weightAdjustedTarget', 'setPerformance'],
  'shared/deload.js': ['deloadAdvice'],
  'shared/e1rm.js': ['estimateOneRepMax'],
  'shared/recap.js': ['liftVerdict', 'capVerdictToTargets', 'floorVerdictToTargets', 'summarizeVerdicts'],
  'client/src/progressionHint.js': ['computeProgressionHint'],
  'server/statsWeeks.js': ['selectProgressWeeks'],
};
const tests = ['shared/algorithm.test.js', 'shared/deload.test.js', 'shared/e1rm.test.js', 'shared/recap.test.js',
               'client/src/progressionHint.test.js', 'server/statsWeeks.test.js'];

for (const [file, fns] of Object.entries(modules)) {
  mkdirSync(dirname(join(work, file)), { recursive: true });
  let code = readFileSync(join(src, file), 'utf8');
  code += `\nimport { appendFileSync as __append } from 'node:fs';\n`;
  code += `const __ser = v => JSON.stringify(v, (k, x) => x instanceof Map ? Object.fromEntries(x) : x === undefined ? null : x);\n`;
  for (const fn of fns) {
    code += `{ const __o = ${fn}; let __depth = 0;
  ${fn} = function (...args) { __depth++; try { const r = __o(...args);
    if (__depth === 1) __append(${JSON.stringify(log)}, __ser({ fn: ${JSON.stringify(fn)}, args, result: r === undefined ? null : r }) + '\\n');
    return r; } finally { __depth--; } }; }\n`;
  }
  writeFileSync(join(work, file), code);
}
for (const t of tests) {
  cpSync(join(src, t), join(work, t));
  execFileSync('node', [join(work, t)], { stdio: 'inherit' });
}

// Seeded fuzz corpus for the progression core.
const { nextExerciseTargets, weightAdjustedTarget } = await import(join(work, 'shared/algorithm.js'));
const { computeProgressionHint } = await import(join(work, 'client/src/progressionHint.js'));
let seed = 1;
const rnd = () => { seed = (seed * 1103515245 + 12345) % 2147483648; return seed / 2147483648; };
const pick = a => a[Math.floor(rnd() * a.length)];
for (let i = 0; i < 1500; i++) {
  const repMin = pick([5, 6, 8, 10, 12]), repMax = repMin + pick([2, 4, 5, 8]);
  const equipment = pick(['barbell', 'dumbbell', 'cable', 'machine', 'bodyweight']);
  const opts = { repMin, repMax, increment: pick([0, 1, 1.25, 2.5, 5]), equipment, tempo: pick(['normal', 'fast', 'slow']) };
  if (rnd() < 0.15) opts.pauseWeight = true;
  if (rnd() < 0.2) opts.weightCapKg = pick([20, 25, 40, 62.5, 100]);
  const n = 1 + Math.floor(rnd() * 5);
  const setData = Array.from({ length: n }, (_, k) => {
    const tw = equipment === 'bodyweight' ? pick([null, 0, 75]) : pick([null, 10, 20, 22.5, 40, 60, 61.5, 100, 140]);
    const tr = repMin + Math.floor(rnd() * (repMax - repMin + 1));
    const r = rnd();
    const logged = r < 0.15 ? null : r < 0.25 ? { weight_used: null, reps_done: null, skipped: 1 }
      : { weight_used: rnd() < 0.7 ? tw : pick([null, 0, 15, 20, 37.5, 55, 65, 80, 120]), reps_done: Math.max(0, tr + Math.floor(rnd() * 9) - 4), skipped: 0 };
    return { set_num: k + 1, target: { weight: tw, reps: tr }, priorFloorMiss: rnd() < 0.3, logged };
  });
  nextExerciseTargets(setData, opts);
  weightAdjustedTarget(pick([null, setData[0].target]), pick([null, 0, 50, 58, 60, 66, 70, 100]), { repMin, repMax });
  const isBodyweight = rnd() < 0.2;
  computeProgressionHint({
    sets: setData.map(s => ({ weight: s.target.weight, reps: s.target.reps,
      prev_weight: rnd() < 0.8 ? pick([null, 10, 20, 40, 60, 61.5, 100]) : null, prev_reps: rnd() < 0.85 ? repMin + Math.floor(rnd() * 6) - 1 : null })),
    repMin, repMax, exerciseComplete: rnd() < 0.05, isBodyweight, unit: pick(['kg', 'lbs']),
  });
}

const byFn = {};
for (const line of readFileSync(log, 'utf8').split('\n').filter(Boolean)) {
  const c = JSON.parse(line);
  (byFn[c.fn] ??= []).push({ args: c.args, result: c.result });
}
mkdirSync(outDir, { recursive: true });
for (const [fn, calls] of Object.entries(byFn)) {
  writeFileSync(join(outDir, `${fn}.json`), JSON.stringify(calls));
  console.log(`${fn}: ${calls.length} calls`);
}
