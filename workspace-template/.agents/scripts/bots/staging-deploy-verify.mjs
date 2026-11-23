#!/usr/bin/env node
// Pool 0 Bot: staging-deploy-verify (Staging deploy & verification without Gatekeeper bypass, 0 LLM tokens).
import fs from 'node:fs';
import path from 'node:path';
import {
  ALLOWED_SERVICES,
  resolvePaths,
  loadBotsConfig,
  parseArgs,
  execSafeSync,
  execSafeAsync,
  execGroupAsync,
  httpGetJson,
  checkDockerCompose,
  verifyGatesReadOnly,
  scrubSecrets,
  tailLines,
  emitResult,
} from './_bot-lib.mjs';

const startedAt = new Date().toISOString();
const startMs = Date.now();
const paths = resolvePaths();
const args = parseArgs(process.argv.slice(2));
const mode = args.mode || 'verify';

if (mode !== 'verify' && mode !== 'deploy') {
  emitResult({
    ok: false,
    botId: 'staging-deploy-verify',
    mode,
    startedAt,
    finishedAt: new Date().toISOString(),
    durationMs: Date.now() - startMs,
    summary: `Unsupported mode "${mode}" (allowed: verify, deploy).`,
    checks: [{ id: 'modeCheck', status: 'FAIL', detail: `Unsupported mode: ${mode}` }],
    metrics: {},
    estimatedTokensSaved: 0,
  });
}

const config = loadBotsConfig(paths.botsConfigFile);
const botCfg = config.bots['staging-deploy-verify'];
const allowedSet = new Set(
  (Array.isArray(botCfg.allowedServices) ? botCfg.allowedServices : ALLOWED_SERVICES).filter((s) =>
    ALLOWED_SERVICES.includes(s)
  )
);

const checks = [];
const metrics = {};

// Validate Staging environment before any deploy action
const preAbout = await httpGetJson(`${paths.backendBaseUrl}/api/system/about`, { timeoutMs: 3000 });
const preEnv = String(preAbout.data?.environment || '').toUpperCase();
if (mode === 'deploy' && (!preAbout.ok || preEnv !== 'STAGING')) {
  emitResult({
    ok: false,
    botId: 'staging-deploy-verify',
    mode,
    startedAt,
    finishedAt: new Date().toISOString(),
    durationMs: Date.now() - startMs,
    summary: `Refused deploy: backend /api/system/about did not confirm STAGING (got "${preEnv || 'unreachable'}").`,
    checks: [{ id: 'stagingGuard', status: 'FAIL', detail: `environment=${preEnv || 'unreachable'} HTTP=${preAbout.status}` }],
    metrics: {},
    estimatedTokensSaved: 0,
  });
}

let deployTail = null;
let deployedServices = [];
if (mode === 'deploy') {
  if (!args.services.length) {
    emitResult({
      ok: false,
      botId: 'staging-deploy-verify',
      mode,
      startedAt,
      finishedAt: new Date().toISOString(),
      durationMs: Date.now() - startMs,
      summary: 'Refused deploy: --services list is required and cannot be empty.',
      checks: [{ id: 'serviceAllowlist', status: 'FAIL', detail: 'Empty service list' }],
      metrics: {},
      estimatedTokensSaved: 0,
    });
  }
  const invalid = args.services.filter((s) => !/^[a-z0-9-]+$/.test(s) || !ALLOWED_SERVICES.includes(s) || !allowedSet.has(s));
  if (invalid.length > 0) {
    emitResult({
      ok: false,
      botId: 'staging-deploy-verify',
      mode,
      startedAt,
      finishedAt: new Date().toISOString(),
      durationMs: Date.now() - startMs,
      summary: `Refused deploy: disallowed service(s): ${invalid.join(', ')}`,
      checks: [{ id: 'serviceAllowlist', status: 'FAIL', detail: `Disallowed services: ${invalid.join(', ')}` }],
      metrics: {},
      estimatedTokensSaved: 0,
    });
  }
  deployedServices = [...new Set(args.services)];
  checks.push({ id: 'serviceAllowlist', status: 'PASS', detail: `Allowlisted deploy targets: ${deployedServices.join(', ')}` });

  const totalTimeoutMs = Math.min(600000, Math.max(20000, (Number(botCfg.timeoutSec) || 300) * 1000));
  const deployBudgetMs = Math.max(15000, totalTimeoutMs - 60000);
  const deployRes = await execGroupAsync('bash', [path.join(paths.repoRoot, 'deploy-staging.sh'), ...deployedServices], {
    cwd: paths.repoRoot,
    timeoutMs: deployBudgetMs,
  });
  deployTail = tailLines(`${deployRes.stdout}\n${deployRes.stderr}`, botCfg.maxLogLines || 80);
  checks.push({
    id: 'deployExecution',
    status: deployRes.ok ? 'PASS' : 'FAIL',
    detail: deployRes.ok
      ? `deploy-staging.sh succeeded for ${deployedServices.join(', ')}`
      : deployRes.timedOut
        ? `timed out after ${Math.round(deployBudgetMs / 1000)}s (process group terminated cleanly)`
        : `exit=${deployRes.code}`,
  });
  if (!deployRes.ok) {
    emitResult({
      ok: false,
      botId: 'staging-deploy-verify',
      mode,
      startedAt,
      finishedAt: new Date().toISOString(),
      durationMs: Date.now() - startMs,
      summary: `Staging deploy failed (exit=${deployRes.code})`,
      checks,
      metrics: { deployedServices, deployLogTail: deployTail },
      estimatedTokensSaved: 25000,
    });
  }
}

// Git HEAD & pending changed services vs .last-staging-deploy (read-only)
const headRes = execSafeSync('git', ['rev-parse', '--short', 'HEAD'], { cwd: paths.repoRoot });
const headSha = headRes.ok ? headRes.stdout.trim() : 'unknown';
let lastDeploySha = 'none';
const deployStampPath = path.join(paths.repoRoot, '.last-staging-deploy');
if (fs.existsSync(deployStampPath)) {
  lastDeploySha = fs.readFileSync(deployStampPath, 'utf8').trim().slice(0, 8) || 'empty';
}
const changedOut = new Set();
const stRes = execSafeSync('git', ['status', '--porcelain'], { cwd: paths.repoRoot });
if (stRes.ok) {
  for (const line of stRes.stdout.split(/\r?\n/)) {
    const file = line.slice(3).trim();
    if (!file) continue;
    const m = file.match(/^(services\/([^/]+)|admin-panel|platform-docs|deploy-agent)\//);
    if (m) changedOut.add(m[2] || m[1]);
  }
}
checks.push({
  id: 'deploySyncState',
  status: 'PASS',
  detail: `HEAD=${headSha} .last-staging-deploy=${lastDeploySha} dirtyModules=${changedOut.size ? Array.from(changedOut).join(',') : 'none'}`,
});
metrics.head = headSha;
metrics.lastStagingDeploy = lastDeploySha;
metrics.dirtyModules = Array.from(changedOut);

// Compose containers
const dockerRes = checkDockerCompose(paths.repoRoot, 10000);
checks.push(dockerRes.check);
metrics.docker = dockerRes.metrics;

// Live Staging HTTP probes
const [uiRes, docsRes] = await Promise.all([
  httpGetJson(`${paths.backendBaseUrl}/`, { timeoutMs: 4000 }),
  httpGetJson(`${paths.backendBaseUrl}/platform-docs/`, { timeoutMs: 4000 }),
]);
checks.push({
  id: 'adminPanelHttp',
  status: uiRes.status === 200 ? 'PASS' : 'FAIL',
  detail: `GET / -> HTTP ${uiRes.status}`,
});
checks.push({
  id: 'platformDocsHttp',
  status: docsRes.status === 200 ? 'PASS' : 'FAIL',
  detail: `GET /platform-docs/ -> HTTP ${docsRes.status}`,
});

// Contextual help verification (`npm run verify:help`)
if (botCfg.autoVerifyHelp !== false) {
  const helpRes = await execSafeAsync('npm', ['run', 'verify:help'], {
    cwd: path.join(paths.repoRoot, 'admin-panel'),
    timeoutMs: 45000,
  });
  const helpLast = scrubSecrets((helpRes.stdout || helpRes.stderr || '').trim().split(/\r?\n/).pop() || '');
  checks.push({
    id: 'verifyHelpCoverage',
    status: helpRes.ok ? 'PASS' : 'FAIL',
    detail: helpLast || (helpRes.ok ? 'verify:help passed' : `exit=${helpRes.code}`),
  });
} else {
  checks.push({ id: 'verifyHelpCoverage', status: 'SKIP', detail: 'Disabled via autoVerifyHelp=false' });
}

// Read-only Gatekeeper verification (never mutates/bypasses)
const gatesCheck = verifyGatesReadOnly(paths.repoRoot);
checks.push({ id: 'gatekeeperStatus', ...gatesCheck });

if (deployedServices.length > 0) metrics.deployedServices = deployedServices;
if (deployTail) metrics.deployLogTail = deployTail;
if (mode === 'deploy') {
  metrics.skillsGateReminder =
    'Deploy executed via deploy-staging.sh: remember to evaluate skills via bash .agents/scripts/run-skills-gate.sh <UPDATED|NO_UPDATE_NEEDED> ... before stopping or committing.';
}

const failCount = checks.filter((c) => c.status === 'FAIL').length;
const warnCount = checks.filter((c) => c.status === 'WARN').length;
const passCount = checks.filter((c) => c.status === 'PASS').length;

emitResult({
  ok: failCount === 0,
  botId: 'staging-deploy-verify',
  mode,
  startedAt,
  finishedAt: new Date().toISOString(),
  durationMs: Date.now() - startMs,
  summary: `${passCount} PASS, ${warnCount} WARN, ${failCount} FAIL`,
  checks,
  metrics,
  estimatedTokensSaved: 25000,
});
