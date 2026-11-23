#!/usr/bin/env node
// Pool 0 Bot: ops-preflight (100% read-only operational pre-flight check, 0 LLM tokens).
import fs from 'node:fs';
import path from 'node:path';
import {
  resolvePaths,
  loadBotsConfig,
  parseArgs,
  execSafeSync,
  httpGetJson,
  readJsonNoSymlink,
  checkDockerCompose,
  scrubSecrets,
  emitResult,
} from './_bot-lib.mjs';

const startedAt = new Date().toISOString();
const startMs = Date.now();
const paths = resolvePaths();
const args = parseArgs(process.argv.slice(2));
const mode = args.mode || 'readonly';

if (mode !== 'readonly') {
  emitResult({
    ok: false,
    botId: 'ops-preflight',
    mode,
    startedAt,
    finishedAt: new Date().toISOString(),
    durationMs: Date.now() - startMs,
    summary: `Unsupported mode "${mode}" (only readonly is allowed).`,
    checks: [{ id: 'modeCheck', status: 'FAIL', detail: `Unsupported mode: ${mode}` }],
    metrics: {},
    estimatedTokensSaved: 0,
  });
}

const config = loadBotsConfig(paths.botsConfigFile);
const botCfg = config.bots['ops-preflight'];
const callerJwt = String(process.env.AGY_BOT_CALLER_JWT || '').trim();
delete process.env.AGY_BOT_CALLER_JWT;

const checks = [];
const metrics = {};

// 1. Docker Compose container states
const dockerRes = checkDockerCompose(paths.repoRoot, 10000);
checks.push(dockerRes.check);
metrics.docker = dockerRes.metrics;

// 2. Gatekeeper GET health check (never POST/sign)
const gkRes = await httpGetJson(paths.gatekeeperHealthUrl, { timeoutMs: 2500 });
const gkHealthy =
  gkRes.ok &&
  (Boolean(gkRes.data?.ok) || String(gkRes.data?.status || '').toUpperCase() === 'UP');
checks.push({
  id: 'gatekeeperHealth',
  status: gkHealthy ? 'PASS' : 'FAIL',
  detail: gkHealthy ? 'ma-gatekeeper healthy on 127.0.0.1:18099' : `HTTP ${gkRes.status} (${scrubSecrets(gkRes.raw)})`,
});
metrics.gatekeeperHealthy = gkHealthy;

// 3. Fleet Push Hub health check
const hubRes = await httpGetJson(paths.fleetHealthUrl, { timeoutMs: 2500 });
const hubOk = hubRes.ok && Boolean(hubRes.data?.ok);
checks.push({
  id: 'fleetHubHealth',
  status: hubOk ? 'PASS' : 'FAIL',
  detail: hubOk
    ? `schema=${hubRes.data.schemaVersion} commit=${String(hubRes.data.latestCommit || '').slice(0, 8)} streams=${hubRes.data.connectedCount}`
    : `HTTP ${hubRes.status} (${scrubSecrets(hubRes.raw)})`,
});
metrics.fleetHub = hubOk
  ? {
      schemaVersion: hubRes.data.schemaVersion,
      latestCommit: String(hubRes.data.latestCommit || '').slice(0, 8),
      connectedCount: hubRes.data.connectedCount,
    }
  : null;

// 4. Gemini Budget Meter + Local Context Guard
if (botCfg.includeQuotaMeter !== false) {
  const budgetScript = path.join(paths.repoRoot, '.agents', 'scripts', 'gemini-budget.js');
  const budgetExec = fs.existsSync(budgetScript)
    ? execSafeSync(process.execPath, [budgetScript, '--json'], { cwd: paths.repoRoot, timeoutMs: 10000 })
    : { ok: false, stdout: '', stderr: 'gemini-budget.js not found' };
  let budgetJson = null;
  if (budgetExec.ok) {
    try {
      budgetJson = JSON.parse(budgetExec.stdout);
    } catch {}
  }
  const quotaRes = readJsonNoSymlink(paths.quotaFile);
  const localRes = readJsonNoSymlink(paths.localRoutingFile);
  const remPct = budgetJson?.remaining_pct ?? quotaRes.data?.gemini_remaining_pct ?? null;
  const reserveMode = Boolean(budgetJson?.quota_state?.reserve_passthrough_mode ?? quotaRes.data?.reserve_passthrough_mode);
  const hardLimit = budgetJson?.thresholds?.ctx_hard_limit_tokens ?? localRes.data?.gemini_quota_guard?.ctx_hard_limit_tokens ?? null;
  const warnLimit = budgetJson?.thresholds?.ctx_warn_tokens ?? localRes.data?.gemini_quota_guard?.ctx_warn_tokens ?? null;

  checks.push({
    id: 'quotaMeter',
    status: !budgetJson ? 'WARN' : reserveMode ? 'WARN' : 'PASS',
    detail: budgetJson
      ? `5h remaining=${remPct}% reserve=${reserveMode} ctxLimits=${warnLimit}/${hardLimit}`
      : `Unable to parse gemini-budget JSON (${scrubSecrets(budgetExec.stderr)})`,
  });
  metrics.quota = { remainingPct: remPct, reserveMode, ctxWarnTokens: warnLimit, ctxHardLimitTokens: hardLimit };
} else {
  checks.push({ id: 'quotaMeter', status: 'SKIP', detail: 'Disabled in offload-bots.json' });
}

// 5. Shared Pool Cooldown Cache (symlink-safe)
if (botCfg.includeCooldowns !== false) {
  const cdRes = readJsonNoSymlink(paths.cooldownsFile);
  if (!cdRes.ok && cdRes.error === 'missing') {
    checks.push({ id: 'poolCooldowns', status: 'PASS', detail: 'No pool cooldowns cached (all external pools clear)' });
    metrics.poolCooldowns = { active: 0, expired: 0 };
  } else if (!cdRes.ok) {
    checks.push({ id: 'poolCooldowns', status: 'WARN', detail: `Cooldown cache skipped (${cdRes.error})` });
    metrics.poolCooldowns = { active: 0, expired: 0, error: cdRes.error };
  } else {
    const nowEpoch = Math.floor(Date.now() / 1000);
    const entries = cdRes.data && typeof cdRes.data === 'object' ? Object.entries(cdRes.data) : [];
    const activeKeys = [];
    let expired = 0;
    for (const [k, v] of entries) {
      const until = Number(v?.until_epoch || 0);
      if (until > nowEpoch) activeKeys.push(k);
      else expired += 1;
    }
    checks.push({
      id: 'poolCooldowns',
      status: activeKeys.length > 0 ? 'WARN' : 'PASS',
      detail: activeKeys.length > 0 ? `Active cooldowns (${activeKeys.length}): ${activeKeys.join(', ')}` : `0 active cooldowns (${expired} expired)`,
    });
    metrics.poolCooldowns = { active: activeKeys.length, expired, activeKeys };
  }
} else {
  checks.push({ id: 'poolCooldowns', status: 'SKIP', detail: 'Disabled in offload-bots.json' });
}

// 6. Hardware Override Hygiene (active_overrides.json == {})
const overrideCandidates = [
  path.join(paths.repoRoot, 'active_overrides.json'),
  path.join(paths.repoRoot, 'scratch', 'active_overrides.json'),
];
const nonEmptyOverrides = [];
for (const fp of overrideCandidates) {
  const ov = readJsonNoSymlink(fp);
  if (ov.ok && ov.data && typeof ov.data === 'object' && Object.keys(ov.data).length > 0) {
    nonEmptyOverrides.push(`${path.relative(paths.repoRoot, fp)} (${Object.keys(ov.data).length} keys)`);
  }
}
checks.push({
  id: 'activeOverridesHygiene',
  status: nonEmptyOverrides.length > 0 ? 'WARN' : 'PASS',
  detail: nonEmptyOverrides.length > 0 ? `Non-empty hardware overrides: ${nonEmptyOverrides.join(', ')}` : 'Clean (no active hardware overrides)',
});

// 7. Backend /api/system/about + Aggregate Modems/SMSC Summary (strictly Staging, never hits RapidLogic/1.1 modems directly)
const aboutRes = await httpGetJson(`${paths.backendBaseUrl}/api/system/about`, { timeoutMs: 3000 });
const stagingEnv = String(aboutRes.data?.environment || '').toUpperCase();
checks.push({
  id: 'stagingEnvironment',
  status: aboutRes.ok && stagingEnv === 'STAGING' ? 'PASS' : 'FAIL',
  detail: aboutRes.ok ? `environment=${stagingEnv} version=${aboutRes.data?.version || 'unknown'}` : `HTTP ${aboutRes.status}`,
});
metrics.stagingEnvironment = stagingEnv || null;

if (botCfg.includeBackendSummary !== false && callerJwt && stagingEnv === 'STAGING') {
  const authHeader = { Authorization: `Bearer ${callerJwt}` };
  const [modemsRes, smscsRes] = await Promise.all([
    httpGetJson(`${paths.backendBaseUrl}/api/admin/hardware/modems`, { timeoutMs: 3500, headers: authHeader }),
    httpGetJson(`${paths.backendBaseUrl}/api/admin/smsc-suppliers`, { timeoutMs: 3500, headers: authHeader }),
  ]);
  if (modemsRes.ok && smscsRes.ok) {
    const modems = Array.isArray(modemsRes.data) ? modemsRes.data : Array.isArray(modemsRes.data?.data) ? modemsRes.data.data : [];
    const smscs = Array.isArray(smscsRes.data) ? smscsRes.data : Array.isArray(smscsRes.data?.data) ? smscsRes.data.data : [];
    const boundSmscs = smscs.filter((s) => String(s.bindStatus || s.status || '').toUpperCase() === 'BOUND' || Number(s.connectedSessions || 0) > 0).length;
    checks.push({
      id: 'backendApiSummary',
      status: 'PASS',
      detail: `modems=${modems.length}, smscSuppliers=${smscs.length} (bound=${boundSmscs})`,
    });
    metrics.backendSummary = { modemsTotal: modems.length, smscsTotal: smscs.length, smscsBound: boundSmscs };
  } else {
    checks.push({
      id: 'backendApiSummary',
      status: 'WARN',
      detail: `Read-only summary partial (modems HTTP ${modemsRes.status}, smscs HTTP ${smscsRes.status})`,
    });
  }
} else {
  checks.push({
    id: 'backendApiSummary',
    status: 'SKIP',
    detail: botCfg.includeBackendSummary === false ? 'Disabled in offload-bots.json' : 'No caller JWT provided (CLI read-only mode)',
  });
}

const hasFail = checks.some((c) => c.status === 'FAIL');
const warnCount = checks.filter((c) => c.status === 'WARN').length;
const passCount = checks.filter((c) => c.status === 'PASS').length;

emitResult({
  ok: !hasFail,
  botId: 'ops-preflight',
  mode,
  startedAt,
  finishedAt: new Date().toISOString(),
  durationMs: Date.now() - startMs,
  summary: `${passCount} PASS, ${warnCount} WARN, ${checks.filter((c) => c.status === 'FAIL').length} FAIL`,
  checks,
  metrics,
  estimatedTokensSaved: 18000,
});
