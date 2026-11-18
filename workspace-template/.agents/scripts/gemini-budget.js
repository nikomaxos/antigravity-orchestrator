#!/usr/bin/env node
// =============================================================================
// Gemini Rolling-Window Budget Meter & Automatic Reserve Trigger (`gemini-budget.js`)
// =============================================================================
// Zero-dependency (Node >= 14) self-meter for Antigravity Gemini quota.
// Antigravity exposes NO quota API to hooks, so we meter ourselves by summing the
// token usage of PLANNER_RESPONSE steps recorded in every conversation transcript:
//   ~/.gemini/antigravity/brain/<conv>/.system_generated/logs/transcript.jsonl
// over a rolling 5-hour window AND a rolling 7-day window, compare with budgets in
// model-routing.json -> `gemini_quota_guard`, and (when `auto`) flip
// ~/.gemini/config/gemini-quota.json into Zero-Gemini Pass-Through Reserve Mode.
//
// CLI:
//   node gemini-budget.js --status                 human-readable report (read-only)
//   node gemini-budget.js --json                   JSON report (read-only)
//   node gemini-budget.js --apply [--json]         evaluate + auto-switch reserve/normal
//   node gemini-budget.js --hook [--conv <id>]     PreInvocation fragment JSON
//                                                  {statusSuffix, systemMessages[], ...}
//                                                  (reads hook stdin JSON if piped)
//   node gemini-budget.js --calibrate [--at ISO] [--safety 0.95]
//                                                  observed usage in the 5h window ending
//                                                  at the last metered step <= --at
// Env overrides (tests / non-standard installs):
//   AGY_GEMINI_QUOTA_FILE, AGY_BRAIN_DIR, AGY_GEMINI_BUDGET_CACHE,
//   AGY_MODEL_ROUTING_FILE, AGY_GEMINI_GUARD_STATE, AGY_GEMINI_BUDGET_NOW (ISO, tests)
// =============================================================================
'use strict';

const fs = require('fs');
const path = require('path');
const os = require('os');

const isWin = process.platform === 'win32';
const USER_HOME = process.env.HOME || os.homedir() || (isWin ? process.env.USERPROFILE || '' : '/home/nick');
const CONFIG_DIR = path.join(USER_HOME, '.gemini', 'config');
const QUOTA_FILE = process.env.AGY_GEMINI_QUOTA_FILE || path.join(CONFIG_DIR, 'gemini-quota.json');
const BRAIN_DIR = process.env.AGY_BRAIN_DIR || path.join(USER_HOME, '.gemini', 'antigravity', 'brain');
const CACHE_FILE = process.env.AGY_GEMINI_BUDGET_CACHE || path.join(CONFIG_DIR, '.gemini-budget-cache.json');
const GUARD_STATE_FILE = process.env.AGY_GEMINI_GUARD_STATE || path.join(CONFIG_DIR, '.gemini-guard-state.json');
const HOUR = 3600 * 1000;
const CACHE_VERSION = 2;

// Calibrated 2026-11-18 from the real 5h-limit exhaustion event (see --calibrate).
const DEFAULT_GUARD = {
  enabled: true,
  auto: true,
  window_hours: 5,
  five_hour_token_budget: 226800000,
  weekly_token_budget: null,
  reserve_threshold_pct: 10,
  restore_threshold_pct: 25,
  warn_threshold_pct: 30,
  ctx_hard_limit_tokens: 200000,
  ctx_warn_tokens: 150000,
  cache_read_weight: 1.0,
  reinject_minutes: 15,
  exclude_model_regex: 'claude|opus|sonnet|haiku|gpt|codex|deepseek',
};

const nowMs = () => (process.env.AGY_GEMINI_BUDGET_NOW ? Date.parse(process.env.AGY_GEMINI_BUDGET_NOW) : Date.now());

function readJson(p) {
  try {
    return JSON.parse(fs.readFileSync(p, 'utf8').replace(/^\uFEFF/, ''));
  } catch {
    return null;
  }
}

function writeJsonAtomic(p, obj) {
  const dir = path.dirname(p);
  fs.mkdirSync(dir, { recursive: true });
  const tmp = path.join(dir, `.${path.basename(p)}.${process.pid}.${Date.now()}.tmp`);
  fs.writeFileSync(tmp, JSON.stringify(obj, null, 2) + '\n', 'utf8');
  fs.renameSync(tmp, p);
}

function resolveRoutingFiles(repoRoot) {
  const list = [];
  if (process.env.AGY_MODEL_ROUTING_FILE) list.push(process.env.AGY_MODEL_ROUTING_FILE);
  if (repoRoot) list.push(path.join(repoRoot, '.agents', 'config', 'model-routing.json'));
  list.push(path.join(__dirname, '..', 'config', 'model-routing.json'));
  list.push(path.join(CONFIG_DIR, 'model-routing.json'));
  return list;
}

function loadGuardConfig(repoRoot) {
  for (const f of resolveRoutingFiles(repoRoot)) {
    const j = readJson(f);
    if (j && j.gemini_quota_guard && typeof j.gemini_quota_guard === 'object') {
      return Object.assign({}, DEFAULT_GUARD, j.gemini_quota_guard, { _source: f });
    }
  }
  return Object.assign({}, DEFAULT_GUARD, { _source: 'defaults' });
}

// -----------------------------------------------------------------------------
// Transcript scanning (incremental, cached by byte offset)
// -----------------------------------------------------------------------------
function listTranscripts(sinceMs) {
  const out = [];
  let dirs = [];
  try {
    dirs = fs.readdirSync(BRAIN_DIR);
  } catch {
    return out;
  }
  for (const d of dirs) {
    const f = path.join(BRAIN_DIR, d, '.system_generated', 'logs', 'transcript.jsonl');
    let st;
    try {
      st = fs.statSync(f);
    } catch {
      continue;
    }
    if (st.mtimeMs >= sinceMs) out.push({ conv: d, file: f, size: st.size, mtimeMs: st.mtimeMs });
  }
  return out;
}

function parsePlannerLine(line) {
  if (line.indexOf('"PLANNER_RESPONSE"') === -1) return null;
  let j;
  try {
    j = JSON.parse(line);
  } catch {
    return null;
  }
  if (!j || j.type !== 'PLANNER_RESPONSE') return null;
  const ts = Date.parse(j.created_at || '');
  if (!Number.isFinite(ts)) return null;
  const inp = Number(j.input_tokens) || 0;
  const cr = Number(j.cache_read_tokens) || 0;
  const outp = Number(j.output_tokens) || 0;
  if (inp + cr + outp === 0) return null;
  const model = j.model || j.model_name || j.modelName || '';
  return [ts, inp, cr, outp, model ? String(model) : ''];
}

function scanFile(entry, cached, keepSinceMs) {
  let rec = cached;
  let headSig = '';
  let fd;
  try {
    fd = fs.openSync(entry.file, 'r');
    const hb = Buffer.alloc(Math.min(128, entry.size));
    fs.readSync(fd, hb, 0, hb.length, 0);
    headSig = hb.toString('base64');
    if (!rec || rec.headSig !== headSig || entry.size < rec.offset) {
      rec = { headSig, offset: 0, events: [], lastCtx: 0, lastTs: 0 };
    } else if (rec.offset > 0) {
      const b = Buffer.alloc(1);
      fs.readSync(fd, b, 0, 1, rec.offset - 1);
      if (b[0] !== 0x0a) rec = { headSig, offset: 0, events: [], lastCtx: 0, lastTs: 0 };
    }
    if (entry.size > rec.offset) {
      const len = entry.size - rec.offset;
      const buf = Buffer.alloc(len);
      fs.readSync(fd, buf, 0, len, rec.offset);
      const lastNl = buf.lastIndexOf(0x0a);
      if (lastNl >= 0) {
        const text = buf.toString('utf8', 0, lastNl);
        for (const line of text.split('\n')) {
          const ev = parsePlannerLine(line);
          if (!ev) continue;
          rec.events.push(ev);
          if (ev[0] >= rec.lastTs) {
            rec.lastTs = ev[0];
            rec.lastCtx = ev[1] + ev[2];
          }
        }
        rec.offset += lastNl + 1;
      }
    }
  } catch {
    // unreadable file: keep previous cache record
  } finally {
    if (fd !== undefined) {
      try {
        fs.closeSync(fd);
      } catch {}
    }
  }
  rec.events = rec.events.filter((e) => e[0] >= keepSinceMs);
  return rec;
}

function loadEvents({ keepDays = 8, noCacheWrite = false } = {}) {
  const now = nowMs();
  const keepSince = now - keepDays * 24 * HOUR;
  let cache = readJson(CACHE_FILE);
  if (!cache || cache.version !== CACHE_VERSION || typeof cache.files !== 'object') cache = { version: CACHE_VERSION, files: {} };
  const files = listTranscripts(keepSince);
  const next = { version: CACHE_VERSION, updated_at: new Date(now).toISOString(), files: {} };
  for (const e of files) {
    const rec = scanFile(e, cache.files[e.file], keepSince);
    rec.conv = e.conv;
    next.files[e.file] = rec;
  }
  if (!noCacheWrite) {
    try {
      writeJsonAtomic(CACHE_FILE, next);
    } catch {}
  }
  return next;
}

// -----------------------------------------------------------------------------
// Model attribution ledger (hook input carries `modelName`; transcripts do not)
// -----------------------------------------------------------------------------
function loadGuardState() {
  const s = readJson(GUARD_STATE_FILE);
  return s && typeof s === 'object' ? Object.assign({ models: {}, injected: {} }, s) : { models: {}, injected: {} };
}

function recordModel(state, conv, modelName, ts) {
  if (!conv || !modelName) return false;
  const arr = state.models[conv] || [];
  const last = arr[arr.length - 1];
  if (last && last[1] === modelName) return false;
  arr.push([ts, modelName]);
  state.models[conv] = arr.slice(-20);
  return true;
}

function modelAt(state, conv, ts) {
  const arr = (state.models && state.models[conv]) || [];
  let m = '';
  for (const [t, name] of arr) {
    if (t <= ts + 60000) m = name;
    else break;
  }
  return m;
}

// -----------------------------------------------------------------------------
// Budget computation
// -----------------------------------------------------------------------------
function computeBudget(opts = {}) {
  const cfg = opts.cfg || loadGuardConfig(opts.repoRoot);
  const now = opts.at || nowMs();
  const data = opts.data || loadEvents({ noCacheWrite: opts.noCacheWrite });
  const state = opts.state || loadGuardState();
  const excl = cfg.exclude_model_regex ? new RegExp(cfg.exclude_model_regex, 'i') : null;
  const w5Start = now - (Number(cfg.window_hours) || 5) * HOUR;
  const wkStart = now - 7 * 24 * HOUR;
  const crw = Number(cfg.cache_read_weight);
  const weight = Number.isFinite(crw) ? crw : 1;
  let used5 = 0;
  let usedWk = 0;
  let steps5 = 0;
  let excluded5 = 0;
  const perConv5 = {};
  let ctx = null;
  for (const [file, rec] of Object.entries(data.files || {})) {
    for (const ev of rec.events || []) {
      const [ts, inp, cr, outp, model] = ev;
      if (ts > now || ts < wkStart) continue;
      const m = model || modelAt(state, rec.conv, ts);
      const tok = inp + outp + cr * weight;
      if (excl && m && excl.test(m)) {
        if (ts >= w5Start) excluded5 += tok;
        continue;
      }
      usedWk += tok;
      if (ts >= w5Start) {
        used5 += tok;
        steps5++;
        perConv5[rec.conv] = (perConv5[rec.conv] || 0) + tok;
      }
    }
    if (opts.conv && rec.conv === opts.conv) ctx = { conversationId: rec.conv, tokens: rec.lastCtx || 0, file };
  }
  const pct = (used, budget) =>
    budget && budget > 0 ? Math.max(0, Math.min(100, Math.round((1 - used / budget) * 1000) / 10)) : null;
  const rem5 = pct(used5, Number(cfg.five_hour_token_budget));
  const remWk = pct(usedWk, cfg.weekly_token_budget ? Number(cfg.weekly_token_budget) : 0);
  const candidates = [rem5, remWk].filter((v) => v !== null);
  const remaining = candidates.length ? Math.min(...candidates) : 100;
  const topConv = Object.entries(perConv5)
    .sort((a, b) => b[1] - a[1])
    .slice(0, 3)
    .map(([c, t]) => ({ conversationId: c, tokens: Math.round(t) }));
  return {
    at: new Date(now).toISOString(),
    enabled: cfg.enabled !== false,
    auto: cfg.auto !== false,
    config_source: cfg._source,
    windows: {
      five_hour: {
        hours: Number(cfg.window_hours) || 5,
        used_tokens: Math.round(used5),
        budget_tokens: Number(cfg.five_hour_token_budget) || null,
        remaining_pct: rem5,
        steps: steps5,
        excluded_non_gemini_tokens: Math.round(excluded5),
        top_conversations: topConv,
      },
      weekly: {
        used_tokens: Math.round(usedWk),
        budget_tokens: cfg.weekly_token_budget ? Number(cfg.weekly_token_budget) : null,
        remaining_pct: remWk,
      },
    },
    remaining_pct: remaining,
    context: ctx,
    thresholds: {
      reserve: Number(cfg.reserve_threshold_pct),
      restore: Number(cfg.restore_threshold_pct),
      warn: Number(cfg.warn_threshold_pct),
      ctx_hard_limit_tokens: Number(cfg.ctx_hard_limit_tokens),
      ctx_warn_tokens: Number(cfg.ctx_warn_tokens),
    },
  };
}

// -----------------------------------------------------------------------------
// Automatic reserve / restore (never overrides a manual --set-reserve)
// -----------------------------------------------------------------------------
const REPLACEMENTS = {
  t1_replacement: 'Pool D (deepseek/deepseek-flash | deepseek-v4-pro) -> Pool C (claude-sonnet-5-5 low) -> Pool B (codex gpt-6-luna low)',
  t2_replacement: 'Pool C (claude-sonnet-5-5 med) -> Pool B (codex gpt-6.1-terra med) -> Pool D (deepseek-v4-pro)',
  t3_replacement: 'Pool B (codex gpt-6.1-sol high) -> Pool C (claude-sonnet-5-5 high) -> Pool D (deepseek-v4-pro)',
  t4_replacement: 'Pool B (codex gpt-6-astra xhigh) -> Pool C (claude-opus-5-5 high) -> Pool D (deepseek-v4-pro)',
};

function buildQuotaState(reserve, pct, source, budget) {
  return Object.assign(
    {
      gemini_remaining_pct: pct,
      threshold_pct: budget ? budget.thresholds.reserve : 10,
      reserve_passthrough_mode: reserve,
      allow_gemini_subagents: !reserve,
      allow_gemini_flash_t1: !reserve,
      source,
    },
    REPLACEMENTS,
    {
      meter: budget
        ? {
            five_hour_used: budget.windows.five_hour.used_tokens,
            five_hour_budget: budget.windows.five_hour.budget_tokens,
            five_hour_remaining_pct: budget.windows.five_hour.remaining_pct,
            weekly_used: budget.windows.weekly.used_tokens,
            weekly_remaining_pct: budget.windows.weekly.remaining_pct,
          }
        : undefined,
      updated_at: new Date(nowMs()).toISOString().replace(/\.\d{3}Z$/, 'Z'),
    }
  );
}

function applyAuto(budget) {
  const cur = readJson(QUOTA_FILE) || {};
  const curReserve = cur.reserve_passthrough_mode === true;
  const curSource = cur.source || (curReserve ? 'manual' : 'legacy');
  const res = { action: 'none', reserve: curReserve, source: curSource };
  if (!budget.enabled || !budget.auto) return res;
  const rem = budget.remaining_pct;
  if (!curReserve && rem < budget.thresholds.reserve) {
    writeJsonAtomic(QUOTA_FILE, buildQuotaState(true, Math.floor(rem), 'auto-meter', budget));
    return { action: 'auto-reserve', reserve: true, source: 'auto-meter' };
  }
  if (curReserve && curSource === 'auto-meter' && rem >= budget.thresholds.restore) {
    writeJsonAtomic(QUOTA_FILE, buildQuotaState(false, Math.floor(rem), 'auto-meter', budget));
    return { action: 'auto-restore', reserve: false, source: 'auto-meter' };
  }
  return res;
}

// -----------------------------------------------------------------------------
// PreInvocation fragment (used by agy-hook.js preflight and preflight.sh)
// -----------------------------------------------------------------------------
function fmtK(n) {
  if (n >= 1e6) return `${(n / 1e6).toFixed(1)}M`;
  return `${Math.round(n / 1000)}K`;
}

function hookFragment(input = {}, repoRoot) {
  const conv = input.conversationId || input.trajectoryId || '';
  const modelName = String(input.modelName || '');
  const cfg = loadGuardConfig(repoRoot);
  const result = { statusSuffix: '', systemMessages: [], budget: null, applied: null };
  if (cfg.enabled === false) return result;
  const state = loadGuardState();
  const now = nowMs();
  let stateDirty = recordModel(state, conv, modelName, now);
  const budget = computeBudget({ cfg, state, conv, repoRoot });
  const applied = applyAuto(budget);
  result.budget = budget;
  result.applied = applied;
  const rem = budget.remaining_pct;
  const w5 = budget.windows.five_hour;
  const wk = budget.windows.weekly;
  const ctxTok = budget.context ? budget.context.tokens : 0;
  const parts = [`⛽ Gemini5h=${w5.remaining_pct ?? 'n/a'}%`];
  if (wk.remaining_pct !== null) parts.push(`wk=${wk.remaining_pct}%`);
  if (ctxTok) parts.push(`ctx=${fmtK(ctxTok)}`);
  if (applied.reserve) parts.push(`🚨 RESERVE(${applied.source})`);
  result.statusSuffix = ` | ${parts.join(' ')}`;

  const onGemini = !modelName || !new RegExp(cfg.exclude_model_regex || '^$', 'i').test(modelName);
  const msgs = [];
  const keys = [];
  if (applied.reserve) {
    keys.push('reserve');
    msgs.push(
      `🚨 ZERO-GEMINI RESERVE ACTIVE (source=${applied.source}, metered Gemini remaining=${rem}% | 5h used ${fmtK(w5.used_tokens)}/${fmtK(w5.budget_tokens || 0)}). ` +
        'MANDATORY: do NOT call invoke_subagent or swarm with ANY Gemini model (Carbon/Hydrogen/Argon/3.8 Flash, incl. Model "inherit"/"flash"/"pro"). ' +
        'Route ALL hands-on work via external pools: T1 `bash .agents/scripts/frontier-orchestrate.sh --tier flash`, T2 `--tier ui`, T3 `--tier backend`, T4 `--tier deep` (Pools B/C/D). ' +
        'Keep parent turns minimal (1-step pass-through, no large reads/greps in parent context). ' +
        (onGemini
          ? 'Tell the user in Greek to switch Model Selection to Claude Opus 5.5 / Claude Sonnet 5.5 for orchestration until the Gemini window recovers.'
          : 'Parent is on a non-Gemini model — continue orchestrating, but still no Gemini subagents.')
    );
  } else if (rem < (Number(cfg.warn_threshold_pct) || 30)) {
    keys.push(`warn${Math.floor(rem / 5)}`);
    msgs.push(
      `⚠️ GEMINI BUDGET LOW: metered remaining=${rem}% (5h window ${fmtK(w5.used_tokens)}/${fmtK(w5.budget_tokens || 0)}` +
        (wk.remaining_pct !== null ? `, weekly ${wk.remaining_pct}%` : '') +
        `). Auto Zero-Gemini Reserve triggers below ${budget.thresholds.reserve}%. Prefer frontier-orchestrate.sh (Pools B/C/D) for T2-T4 now, avoid Gemini subagent fan-out, keep parent context small, and briefly inform the user (in Greek).`
    );
  }
  const hard = Number(cfg.ctx_hard_limit_tokens) || 200000;
  const soft = Number(cfg.ctx_warn_tokens) || 150000;
  if (ctxTok > hard) {
    keys.push(`ctxhard${Math.floor(ctxTok / 100000)}`);
    msgs.push(
      `🛑 CONTEXT GUARD: this conversation re-sends ~${fmtK(ctxTok)} tokens on EVERY model call (hard limit ${fmtK(hard)}), burning the Gemini 5h window ~${Math.max(1, Math.round(ctxTok / 50000))}x faster than a fresh chat. ` +
        'BEFORE doing anything else, tell the user (in Greek) to run /compact (or start a new conversation with a short handoff summary) and wait; do not start new large tasks in this context.'
    );
  } else if (ctxTok > soft) {
    keys.push('ctxsoft');
    msgs.push(`⚠️ CONTEXT ${fmtK(ctxTok)} > ${fmtK(soft)}: delegate heavy reads to external pools and suggest /compact to the user soon.`);
  }
  if (msgs.length) {
    const key = keys.join(',');
    const prev = (conv && state.injected[conv]) || null;
    const reinjectMs = (Number(cfg.reinject_minutes) || 15) * 60000;
    if (!prev || prev.key !== key || now - prev.ts >= reinjectMs) {
      result.systemMessages = msgs;
      if (conv) {
        state.injected[conv] = { key, ts: now };
        stateDirty = true;
      }
    }
  }
  if (stateDirty) {
    // prune old conversations
    const cutoff = now - 8 * 24 * HOUR;
    for (const [c, v] of Object.entries(state.injected)) if (!v || v.ts < cutoff) delete state.injected[c];
    for (const [c, arr] of Object.entries(state.models)) if (!arr.length || arr[arr.length - 1][0] < cutoff) delete state.models[c];
    try {
      writeJsonAtomic(GUARD_STATE_FILE, state);
    } catch {}
  }
  return result;
}

// -----------------------------------------------------------------------------
// Calibration from a real exhaustion event
// -----------------------------------------------------------------------------
function calibrate(atMs, safety) {
  const cfg = loadGuardConfig();
  const data = loadEvents({ keepDays: 8 });
  const state = loadGuardState();
  let lastTs = 0;
  let lastConv = '';
  for (const rec of Object.values(data.files)) {
    for (const ev of rec.events) {
      if (ev[0] <= atMs && ev[0] > lastTs) {
        lastTs = ev[0];
        lastConv = rec.conv;
      }
    }
  }
  if (!lastTs) return { error: 'no PLANNER_RESPONSE steps found before --at' };
  const b = computeBudget({ cfg, data, state, at: lastTs, noCacheWrite: true });
  const w = b.windows.five_hour;
  let rawIn = 0;
  let rawCr = 0;
  let rawOut = 0;
  for (const rec of Object.values(data.files)) {
    for (const ev of rec.events) {
      if (ev[0] <= lastTs && ev[0] >= lastTs - w.hours * HOUR) {
        rawIn += ev[1];
        rawCr += ev[2];
        rawOut += ev[3];
      }
    }
  }
  return {
    exhaustion_at: new Date(atMs).toISOString(),
    last_metered_step_at: new Date(lastTs).toISOString(),
    last_metered_conversation: lastConv,
    window_start: new Date(lastTs - w.hours * HOUR).toISOString(),
    steps: w.steps,
    input_tokens: rawIn,
    cache_read_tokens: rawCr,
    output_tokens: rawOut,
    cache_read_weight: Number(cfg.cache_read_weight),
    observed_total_tokens: w.used_tokens,
    safety_factor: safety,
    suggested_five_hour_token_budget: Math.floor((w.used_tokens * safety) / 100000) * 100000,
    top_conversations: w.top_conversations,
  };
}

module.exports = { computeBudget, applyAuto, hookFragment, calibrate, loadGuardConfig, QUOTA_FILE };

// -----------------------------------------------------------------------------
// CLI
// -----------------------------------------------------------------------------
if (require.main === module) {
  const argv = process.argv.slice(2);
  const has = (f) => argv.includes(f);
  const val = (f) => {
    const i = argv.indexOf(f);
    return i >= 0 && i + 1 < argv.length ? argv[i + 1] : null;
  };
  try {
    if (has('--calibrate')) {
      const at = val('--at') ? Date.parse(val('--at')) : nowMs();
      const safety = Number(val('--safety') || 0.95);
      process.stdout.write(JSON.stringify(calibrate(at, safety), null, 2) + '\n');
    } else if (has('--hook')) {
      let input = {};
      if (!process.stdin.isTTY) {
        try {
          const raw = fs.readFileSync(0, 'utf8').replace(/^\uFEFF/, '').trim();
          if (raw) input = JSON.parse(raw);
        } catch {}
      }
      if (val('--conv')) input.conversationId = val('--conv');
      if (val('--model')) input.modelName = val('--model');
      const fr = hookFragment(input, val('--repo') || undefined);
      process.stdout.write(JSON.stringify({ statusSuffix: fr.statusSuffix, systemMessages: fr.systemMessages, remaining_pct: fr.budget ? fr.budget.remaining_pct : null, applied: fr.applied }) + '\n');
    } else {
      const b = computeBudget({ conv: val('--conv') || undefined });
      const applied = has('--apply') ? applyAuto(b) : null;
      const q = readJson(QUOTA_FILE) || {};
      if (has('--json') || has('--apply')) {
        process.stdout.write(JSON.stringify(Object.assign({}, b, { applied, quota_state: { reserve_passthrough_mode: q.reserve_passthrough_mode === true, source: q.source || 'legacy', updated_at: q.updated_at || null } }), null, 2) + '\n');
      } else {
        const w = b.windows.five_hour;
        const wk = b.windows.weekly;
        const lines = [
          `Gemini Budget Meter @ ${b.at}  (config: ${b.config_source}, auto=${b.auto})`,
          `  5h window : used ${fmtK(w.used_tokens)} / ${fmtK(w.budget_tokens || 0)} -> remaining ${w.remaining_pct}%  (${w.steps} steps, excluded non-Gemini ${fmtK(w.excluded_non_gemini_tokens)})`,
          `  7d window : used ${fmtK(wk.used_tokens)} / ${wk.budget_tokens ? fmtK(wk.budget_tokens) : 'unbounded'} -> remaining ${wk.remaining_pct ?? 'n/a'}%`,
          `  EFFECTIVE remaining = ${b.remaining_pct}%  (reserve < ${b.thresholds.reserve}%, restore >= ${b.thresholds.restore}%, warn < ${b.thresholds.warn}%)`,
          `  Quota state: reserve=${q.reserve_passthrough_mode === true} source=${q.source || 'legacy'} updated=${q.updated_at || 'n/a'}`,
          `  Top 5h conversations: ${w.top_conversations.map((c) => `${c.conversationId.slice(0, 8)}=${fmtK(c.tokens)}`).join(', ') || 'none'}`,
        ];
        process.stdout.write(lines.join('\n') + '\n');
      }
    }
  } catch (e) {
    process.stderr.write(`gemini-budget: ${e && e.message ? e.message : e}\n`);
    process.exit(1);
  }
}
