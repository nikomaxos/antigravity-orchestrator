#!/usr/bin/env node
// =============================================================================
// Gemini Rolling-Window Budget Meter & Automatic Reserve Trigger (`gemini-budget.js`)
// =============================================================================
// Zero-dependency (Node >= 14) self-meter for Antigravity Gemini quota.
// Antigravity exposes NO quota API to hooks, so we meter ourselves by summing the
// token usage of PLANNER_RESPONSE steps recorded in every conversation transcript:
//   ~/.gemini/antigravity/brain/<conv>/.system_generated/logs/transcript.jsonl
// over discrete 5-hour quota epochs (starting at first Gemini step after idle/expiry)
// AND a rolling 7-day window, compare with budgets in model-routing.json ->
// `gemini_quota_guard`, and (when `auto`) flip ~/.gemini/config/gemini-quota.json
// into Zero-Gemini Pass-Through Reserve Mode.
//
// CLI:
//   node gemini-budget.js --status                 human-readable report (read-only)
//   node gemini-budget.js --json                   JSON report (read-only)
//   node gemini-budget.js --apply [--json]         evaluate + auto-switch reserve/normal
//   node gemini-budget.js --sync-pct <0..100>      anchor current epoch remaining % to UI
//   node gemini-budget.js --clear-sync             clear any active sync anchor
//   node gemini-budget.js --hook [--conv <id>]     PreInvocation fragment JSON
//                                                  {statusSuffix, systemMessages[], ...}
//                                                  (reads hook stdin JSON if piped)
//   node gemini-budget.js --calibrate [--at ISO] [--safety 0.95]
//                                                  observed usage in the active 5h epoch
//                                                  ending at the last metered step <= --at
// Env overrides (tests / non-standard installs):
//   AGY_GEMINI_QUOTA_FILE, AGY_BRAIN_DIR, AGY_GEMINI_BUDGET_CACHE,
//   AGY_MODEL_ROUTING_FILE, AGY_MODEL_ROUTING_LOCAL_FILE,
//   AGY_GEMINI_GUARD_STATE, AGY_GEMINI_BUDGET_NOW (ISO, tests)
// Machine-local guard overrides (optional, ignored by git/agy-arch-sync):
//   ~/.gemini/config/model-routing.local.json -> { "gemini_quota_guard": { ... } }
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
const CACHE_VERSION = 3;

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

const LOCAL_OVERRIDE_ALLOWLIST = new Set([
  'ctx_hard_limit_tokens',
  'ctx_warn_tokens',
  'reinject_minutes',
  'warn_threshold_pct',
]);

function applyLocalGuardOverrides(cfg) {
  let localFile = '';
  if (process.env.AGY_MODEL_ROUTING_LOCAL_FILE) {
    localFile = process.env.AGY_MODEL_ROUTING_LOCAL_FILE;
  } else if (!process.env.AGY_MODEL_ROUTING_FILE) {
    // Skip host model-routing.local.json when AGY_MODEL_ROUTING_FILE isolates test runs.
    localFile = path.join(CONFIG_DIR, 'model-routing.local.json');
  }
  if (!localFile) return cfg;
  const localJson = readJson(localFile);
  if (!localJson || !localJson.gemini_quota_guard || typeof localJson.gemini_quota_guard !== 'object' || Array.isArray(localJson.gemini_quota_guard)) {
    return cfg;
  }
  const overrides = localJson.gemini_quota_guard;
  const baseWarn = cfg.warn_threshold_pct;
  const baseCtxWarn = cfg.ctx_warn_tokens;
  const baseCtxHard = cfg.ctx_hard_limit_tokens;
  const appliedKeys = new Set();
  for (const key of LOCAL_OVERRIDE_ALLOWLIST) {
    if (!Object.prototype.hasOwnProperty.call(overrides, key)) continue;
    const val = overrides[key];
    if (typeof val !== 'number' || !Number.isFinite(val)) continue;
    if (key === 'warn_threshold_pct') {
      if (val >= 0 && val <= 100) {
        cfg[key] = val;
        appliedKeys.add(key);
      }
    } else if (key === 'reinject_minutes') {
      if (val >= 0) {
        cfg[key] = val;
        appliedKeys.add(key);
      }
    } else {
      // ctx_hard_limit_tokens, ctx_warn_tokens
      if (val > 0) {
        cfg[key] = val;
        appliedKeys.add(key);
      }
    }
  }
  if (Number(cfg.warn_threshold_pct) <= Number(cfg.reserve_threshold_pct)) {
    cfg.warn_threshold_pct = baseWarn;
    appliedKeys.delete('warn_threshold_pct');
  }
  if (Number(cfg.ctx_hard_limit_tokens) <= Number(cfg.ctx_warn_tokens)) {
    cfg.ctx_warn_tokens = baseCtxWarn;
    cfg.ctx_hard_limit_tokens = baseCtxHard;
    appliedKeys.delete('ctx_warn_tokens');
    appliedKeys.delete('ctx_hard_limit_tokens');
  }
  if (appliedKeys.size > 0) cfg._localOverride = localFile;
  return cfg;
}

function loadGuardConfig(repoRoot) {
  let cfg = Object.assign({}, DEFAULT_GUARD, { _source: 'defaults' });
  for (const f of resolveRoutingFiles(repoRoot)) {
    const j = readJson(f);
    if (j && j.gemini_quota_guard && typeof j.gemini_quota_guard === 'object') {
      cfg = Object.assign({}, DEFAULT_GUARD, j.gemini_quota_guard, { _source: f });
      break;
    }
  }
  return applyLocalGuardOverrides(cfg);
}

// -----------------------------------------------------------------------------
// Transcript scanning (incremental, cached by byte offset)
// -----------------------------------------------------------------------------
function listTranscripts(sinceMs) {
  const out = [];
  let entries = [];
  try {
    // Antigravity v2.35+ retains unlimited conversation history by default; skip non-directories
    // and filter strictly by transcript mtimeMs >= sinceMs (8d window) to stay sub-50ms.
    entries = fs.readdirSync(BRAIN_DIR, { withFileTypes: true });
  } catch {
    return out;
  }
  for (const dirent of entries) {
    if (!dirent.isDirectory()) continue;
    const d = dirent.name;
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

function parseCompactResetTs(line) {
  // Fast pre-filter before JSON.parse; authoritative USER_INPUT check follows below.
  if (line.indexOf('"USER_INPUT"') === -1 || line.indexOf('/compact') === -1) return null;
  let j;
  try {
    j = JSON.parse(line);
  } catch {
    return null;
  }
  if (!j || j.type !== 'USER_INPUT' || typeof j.content !== 'string') return null;
  const trimmed = j.content.trim();
  const isCompact =
    /^\/compact(\s|$)/i.test(trimmed) ||
    /^(?:<CONTEXT_SUMMARY>[\s\S]*?<\/CONTEXT_SUMMARY>\s*)?<USER_REQUEST>\s*\/compact(?:\s|<\/USER_REQUEST>|$)/i.test(
      trimmed
    );
  if (!isCompact) return null;
  const ts = Date.parse(j.created_at || '');
  return Number.isFinite(ts) ? ts : null;
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
          if (ev) {
            rec.events.push(ev);
            if (ev[0] >= rec.lastTs) {
              rec.lastTs = ev[0];
              rec.lastCtx = ev[1] + ev[2];
            }
            continue;
          }
          const compactTs = parseCompactResetTs(line);
          if (compactTs !== null && compactTs >= rec.lastTs) {
            rec.lastTs = compactTs;
            rec.lastCtx = 0;
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
  const windowHours = Number(cfg.window_hours) || 5;
  const windowMs = windowHours * HOUR;
  const wkStart = now - 7 * 24 * HOUR;
  const crw = Number(cfg.cache_read_weight);
  const weight = Number.isFinite(crw) ? crw : 1;
  const budget5 = Number(cfg.five_hour_token_budget) || 0;

  // Pass 1: collect non-excluded Gemini events (and excluded events) with ts <= now; sum 7d window.
  const geminiEvents = [];
  const excludedEvents = [];
  let usedWk = 0;
  let ctx = null;
  for (const [file, rec] of Object.entries(data.files || {})) {
    for (const ev of rec.events || []) {
      const [ts, inp, cr, outp, model] = ev;
      if (ts > now) continue;
      const m = model || modelAt(state, rec.conv, ts);
      const tok = inp + outp + cr * weight;
      if (excl && m && excl.test(m)) {
        excludedEvents.push([ts, tok]);
        continue;
      }
      if (ts >= wkStart) usedWk += tok;
      geminiEvents.push([ts, tok, rec.conv]);
    }
    if (opts.conv && rec.conv === opts.conv) ctx = { conversationId: rec.conv, tokens: rec.lastCtx || 0, file };
  }

  // Pass 2: discrete 5h quota epochs starting at the first Gemini step after idle/expiry,
  // anchored against persisted state.active_epoch (survives >8d history truncation) and active sync_anchor.
  geminiEvents.sort((a, b) => a[0] - b[0]);
  const sa = !opts.ignoreSyncAnchor && state && state.sync_anchor && typeof state.sync_anchor === 'object' ? state.sync_anchor : null;
  const saValid = Boolean(
    sa &&
      Number.isFinite(Number(sa.resets_at_ms)) &&
      now < Number(sa.resets_at_ms) &&
      Number.isFinite(Number(sa.synced_remaining_pct))
  );
  const saEpochStart = saValid
    ? Number.isFinite(Number(sa.epoch_start_ms))
      ? Number(sa.epoch_start_ms)
      : Number(sa.resets_at_ms) - windowMs
    : null;
  const storedEpoch =
    !opts.ignoreStoredEpoch &&
    !opts.at &&
    state &&
    state.active_epoch &&
    typeof state.active_epoch === 'object' &&
    Number.isFinite(Number(state.active_epoch.epoch_start_ms)) &&
    Number(state.active_epoch.epoch_start_ms) <= now
      ? state.active_epoch
      : null;

  let epochStart = null;
  let resetsAt = null;
  let used5 = 0;
  let steps5 = 0;
  let excluded5 = 0;
  let perConv5 = {};
  let used5Effective = 0;
  let syncAnchorMeta = null;

  if (saValid && saEpochStart !== null && saEpochStart <= now) {
    epochStart = saEpochStart;
    resetsAt = Number(sa.resets_at_ms);
    for (const [ts, tok, conv] of geminiEvents) {
      if (ts >= epochStart && ts <= now) {
        used5 += tok;
        steps5++;
        perConv5[conv] = (perConv5[conv] || 0) + tok;
      }
    }
    for (const [ts, tok] of excludedEvents) {
      if (ts >= epochStart && ts <= now) excluded5 += tok;
    }
    const anchorBaseUsed = Math.max(0, (1 - Number(sa.synced_remaining_pct) / 100) * budget5);
    const deltaSinceSync = Math.max(0, used5 - (Number(sa.used_tokens_at_sync) || 0));
    used5Effective = anchorBaseUsed + deltaSinceSync;
    syncAnchorMeta = {
      synced_remaining_pct: Number(sa.synced_remaining_pct),
      used_tokens_at_sync: Math.round(Number(sa.used_tokens_at_sync) || 0),
      delta_since_sync: Math.round(deltaSinceSync),
      synced_at: sa.synced_at || null,
      epoch_start: new Date(epochStart).toISOString(),
      resets_at: new Date(resetsAt).toISOString(),
    };
  } else {
    epochStart = storedEpoch ? Number(storedEpoch.epoch_start_ms) : null;
    for (const [ts] of geminiEvents) {
      if (epochStart !== null && ts < epochStart) continue;
      if (epochStart === null || ts >= epochStart + windowMs) {
        epochStart = ts;
      }
    }
    if (epochStart === null || now >= epochStart + windowMs) {
      epochStart = null;
      resetsAt = null;
    } else {
      resetsAt = epochStart + windowMs;
      for (const [ts, tok, conv] of geminiEvents) {
        if (ts >= epochStart && ts <= now) {
          used5 += tok;
          steps5++;
          perConv5[conv] = (perConv5[conv] || 0) + tok;
        }
      }
      for (const [ts, tok] of excludedEvents) {
        if (ts >= epochStart && ts <= now) excluded5 += tok;
      }
    }
    used5Effective = used5;
  }

  const pct = (used, budget) =>
    budget && budget > 0 ? Math.max(0, Math.min(100, Math.round((1 - used / budget) * 1000) / 10)) : null;
  const rem5 = pct(used5Effective, budget5);
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
    local_override_source: cfg._localOverride || null,
    windows: {
      five_hour: {
        hours: windowHours,
        epoch_start: epochStart ? new Date(epochStart).toISOString() : null,
        resets_at: resetsAt ? new Date(resetsAt).toISOString() : null,
        used_tokens: Math.round(used5Effective),
        raw_used_tokens: Math.round(used5),
        budget_tokens: budget5 || null,
        remaining_pct: rem5,
        steps: steps5,
        excluded_non_gemini_tokens: Math.round(excluded5),
        sync_anchor: syncAnchorMeta,
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
  t1_replacement: 'Pool C (claude-sonnet-5-5 low) -> Pool B (codex gpt-6-luna low)',
  t2_replacement: 'Pool C (claude-sonnet-5-5 med) -> Pool B (codex gpt-6.1-terra med)',
  t3_replacement: 'Pool B (codex gpt-6.1-sol high) -> Pool C (claude-sonnet-5-5 high)',
  t4_replacement: 'Pool B (codex gpt-6-astra xhigh) -> Pool C (claude-opus-5-5 high | claude-sonnet-5-5 high)',
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

function updateActiveEpochState(state, budget, fromSyncHint) {
  if (!state || typeof state !== 'object') return false;
  const w5 = budget && budget.windows && budget.windows.five_hour;
  const next =
    w5 && w5.epoch_start && w5.resets_at
      ? {
          epoch_start_ms: Date.parse(w5.epoch_start),
          resets_at_ms: Date.parse(w5.resets_at),
          from_sync: Boolean(
            fromSyncHint !== undefined
              ? fromSyncHint
              : (w5.sync_anchor && state.sync_anchor && state.sync_anchor.from_sync) ||
                  (state.active_epoch && state.active_epoch.from_sync)
          ),
        }
      : null;
  const prev = state.active_epoch || null;
  const same =
    (!prev && !next) ||
    (prev &&
      next &&
      prev.epoch_start_ms === next.epoch_start_ms &&
      prev.resets_at_ms === next.resets_at_ms &&
      Boolean(prev.from_sync) === Boolean(next.from_sync));
  if (!same) {
    if (next) state.active_epoch = next;
    else delete state.active_epoch;
    return true;
  }
  return false;
}

function applyAuto(budget, stateOpt) {
  const st = stateOpt || loadGuardState();
  if (updateActiveEpochState(st, budget) && !stateOpt) {
    try {
      writeJsonAtomic(GUARD_STATE_FILE, st);
    } catch {}
  }
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
  if (updateActiveEpochState(state, budget)) stateDirty = true;
  const applied = applyAuto(budget, state);
  result.budget = budget;
  result.applied = applied;
  const rem = budget.remaining_pct;
  const w5 = budget.windows.five_hour;
  const wk = budget.windows.weekly;
  const ctxTok = budget.context ? budget.context.tokens : 0;
  const parts = [`⛽ Gemini5h=${w5.remaining_pct ?? 'n/a'}%`];
  if (wk.remaining_pct !== null) parts.push(`wk=${wk.remaining_pct}%`);
  if (ctxTok) parts.push(`ctx=${fmtK(ctxTok)}`);
  if (cfg._localOverride) parts.push('⚙local');
  if (applied.reserve) parts.push(`🚨 RESERVE(${applied.source})`);
  result.statusSuffix = ` | ${parts.join(' ')}`;

  const onGemini = !modelName || !new RegExp(cfg.exclude_model_regex || '^$', 'i').test(modelName);
  const msgs = [];
  const keys = [];
  if (applied.reserve) {
    keys.push('reserve');
    msgs.push(
      `🚨 ZERO-GEMINI RESERVE ACTIVE (source=${applied.source}, metered Gemini remaining=${rem}% | 5h used ${fmtK(w5.used_tokens)}/${fmtK(w5.budget_tokens || 0)}). ` +
        'MANDATORY: do NOT call invoke_subagent or swarm with ANY Gemini model (Carbon/Neon/Hydrogen/Argon/3.8 Flash, incl. Orchestrator & Model "inherit"/"flash"/"pro"). ' +
        'Route ALL hands-on work via external pools: T1 `bash .agents/scripts/frontier-orchestrate.sh --tier flash`, T2 `--tier ui`, T3 `--tier backend`, T4 `--tier deep` (Pools B/C; DeepSeek is manual-only). ' +
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
        `). Auto Zero-Gemini Reserve triggers below ${budget.thresholds.reserve}%. Prefer frontier-orchestrate.sh (Pools B/C) for T2-T4 now, avoid Gemini subagent fan-out, keep parent context small, and briefly inform the user (in Greek).`
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
  const b = computeBudget({ cfg, data, state, at: lastTs, noCacheWrite: true, ignoreSyncAnchor: true, ignoreStoredEpoch: true });
  const w = b.windows.five_hour;
  const excl = cfg.exclude_model_regex ? new RegExp(cfg.exclude_model_regex, 'i') : null;
  const epochStartMs = w.epoch_start ? Date.parse(w.epoch_start) : lastTs - w.hours * HOUR;
  let rawIn = 0;
  let rawCr = 0;
  let rawOut = 0;
  for (const rec of Object.values(data.files)) {
    for (const ev of rec.events) {
      if (ev[0] <= lastTs && ev[0] >= epochStartMs) {
        const m = ev[4] || modelAt(state, rec.conv, ev[0]);
        if (excl && m && excl.test(m)) continue;
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
    window_start: new Date(epochStartMs).toISOString(),
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
  const has = (f) => argv.includes(f) || argv.some((a) => a.startsWith(`${f}=`));
  const val = (f) => {
    const i = argv.indexOf(f);
    if (i >= 0 && i + 1 < argv.length) return argv[i + 1];
    const eq = argv.find((a) => a.startsWith(`${f}=`));
    return eq ? eq.slice(f.length + 1) : null;
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
    } else if (has('--sync-pct') || has('--clear-sync')) {
      const repoRoot = val('--repo') || undefined;
      const cfg = loadGuardConfig(repoRoot);
      const state = loadGuardState();
      const now = nowMs();
      if (has('--clear-sync')) {
        delete state.sync_anchor;
        if (state.active_epoch && state.active_epoch.from_sync) delete state.active_epoch;
      } else {
        const rawPct = val('--sync-pct');
        const pctVal = rawPct === null || rawPct === '' ? NaN : Number(rawPct);
        if (!Number.isFinite(pctVal) || pctVal < 0 || pctVal > 100) {
          throw new Error(`--sync-pct requires a number between 0 and 100 (got: '${rawPct}')`);
        }
        const rawB = computeBudget({ cfg, state, ignoreSyncAnchor: true, noCacheWrite: true, repoRoot });
        const w5Raw = rawB.windows.five_hour;
        const windowMs = (Number(cfg.window_hours) || 5) * HOUR;
        const hasRawEpoch = Boolean(w5Raw.epoch_start);
        const epochStartMs = hasRawEpoch ? Date.parse(w5Raw.epoch_start) : now;
        const resetsAtMs = w5Raw.resets_at ? Date.parse(w5Raw.resets_at) : epochStartMs + windowMs;
        state.sync_anchor = {
          synced_remaining_pct: pctVal,
          epoch_start_ms: epochStartMs,
          resets_at_ms: resetsAtMs,
          used_tokens_at_sync: w5Raw.raw_used_tokens ?? w5Raw.used_tokens,
          from_sync: !hasRawEpoch,
          synced_at: new Date(now).toISOString(),
        };
        if (!hasRawEpoch) {
          state.active_epoch = { epoch_start_ms: epochStartMs, resets_at_ms: resetsAtMs, from_sync: true };
        }
      }
      const b = computeBudget({ cfg, state, conv: val('--conv') || undefined, repoRoot });
      let applied = applyAuto(b, state);
      updateActiveEpochState(state, b, has('--clear-sync') ? false : undefined);
      writeJsonAtomic(GUARD_STATE_FILE, state);
      if (applied.action === 'none' && b.enabled && b.auto) {
        const cur = readJson(QUOTA_FILE) || {};
        const curReserve = cur.reserve_passthrough_mode === true;
        const curSource = cur.source || (curReserve ? 'manual' : 'legacy');
        if (!(curReserve && curSource === 'manual')) {
          writeJsonAtomic(QUOTA_FILE, buildQuotaState(curReserve, Math.floor(b.remaining_pct), curReserve ? curSource : 'auto-meter', b));
          applied = { action: has('--clear-sync') ? 'clear-sync' : 'sync-anchor', reserve: curReserve, source: curReserve ? curSource : 'auto-meter' };
        }
      }
      const q = readJson(QUOTA_FILE) || {};
      process.stdout.write(JSON.stringify(Object.assign({}, b, { applied, quota_state: { reserve_passthrough_mode: q.reserve_passthrough_mode === true, source: q.source || 'legacy', updated_at: q.updated_at || null } }), null, 2) + '\n');
    } else {
      const b = computeBudget({ conv: val('--conv') || undefined, repoRoot: val('--repo') || undefined });
      const applied = has('--apply') ? applyAuto(b) : null;
      const q = readJson(QUOTA_FILE) || {};
      if (has('--json') || has('--apply')) {
        process.stdout.write(JSON.stringify(Object.assign({}, b, { applied, quota_state: { reserve_passthrough_mode: q.reserve_passthrough_mode === true, source: q.source || 'legacy', updated_at: q.updated_at || null } }), null, 2) + '\n');
      } else {
        const w = b.windows.five_hour;
        const wk = b.windows.weekly;
        const resetTxt = w.resets_at ? `, resets ${w.resets_at}` : ', idle/expired';
        const syncTxt = w.sync_anchor ? ` [sync=${w.sync_anchor.synced_remaining_pct}%+${fmtK(w.sync_anchor.delta_since_sync)}]` : '';
        const localTxt = b.local_override_source ? `, local: ${b.local_override_source}` : '';
        const lines = [
          `Gemini Budget Meter @ ${b.at}  (config: ${b.config_source}${localTxt}, auto=${b.auto})`,
          `  5h window : used ${fmtK(w.used_tokens)} / ${fmtK(w.budget_tokens || 0)} -> remaining ${w.remaining_pct}%  (${w.steps} steps, excluded non-Gemini ${fmtK(w.excluded_non_gemini_tokens)}${resetTxt})${syncTxt}`,
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
