#!/usr/bin/env node
// Pool 0 Bot: release-pack-sync (deterministic bundle/fleet-sync audit & bounded sync, 0 LLM tokens).
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import {
  resolvePaths,
  loadBotsConfig,
  parseArgs,
  execSafeSync,
  execSafeAsync,
  httpGetJson,
  verifyGatesReadOnly,
  sha256FileNoSymlink,
  readJsonNoSymlink,
  scrubSecrets,
  tailLines,
  emitResult,
} from './_bot-lib.mjs';

const startedAt = new Date().toISOString();
const startMs = Date.now();
const paths = resolvePaths();
const args = parseArgs(process.argv.slice(2));
const mode = args.mode || 'audit';

if (mode !== 'audit' && mode !== 'sync') {
  emitResult({
    ok: false,
    botId: 'release-pack-sync',
    mode,
    startedAt,
    finishedAt: new Date().toISOString(),
    durationMs: Date.now() - startMs,
    summary: `Unsupported mode "${mode}" (allowed: audit, sync).`,
    checks: [{ id: 'modeCheck', status: 'FAIL', detail: `Unsupported mode: ${mode}` }],
    metrics: {},
    estimatedTokensSaved: 0,
  });
}

const config = loadBotsConfig(paths.botsConfigFile);
const botCfg = config.bots['release-pack-sync'];
const checks = [];
const metrics = {};

if (mode === 'sync') {
  if (!fs.existsSync(path.join(paths.orchRepo, '.git'))) {
    emitResult({
      ok: false,
      botId: 'release-pack-sync',
      mode,
      startedAt,
      finishedAt: new Date().toISOString(),
      durationMs: Date.now() - startMs,
      summary: `Orchestrator repo missing at ${paths.orchRepo}`,
      checks: [{ id: 'orchestratorRepo', status: 'FAIL', detail: 'Missing .git repo' }],
      metrics: {},
      estimatedTokensSaved: 0,
    });
  }
  const dirtyWorktree = execSafeSync('git', ['status', '--porcelain'], { cwd: paths.orchRepo });
  const hasDirty = Boolean(dirtyWorktree.ok && dirtyWorktree.stdout.trim());
  if (botCfg.strictCleanWorktree !== false && hasDirty) {
    emitResult({
      ok: false,
      botId: 'release-pack-sync',
      mode,
      startedAt,
      finishedAt: new Date().toISOString(),
      durationMs: Date.now() - startMs,
      summary: 'Refused sync: strictCleanWorktree=true and antigravity-orchestrator has uncommitted or untracked changes.',
      checks: [{ id: 'cleanWorktreeGuard', status: 'FAIL', detail: 'Dirty or untracked changes in antigravity-orchestrator' }],
      metrics: {},
      estimatedTokensSaved: 0,
    });
  }

  if (botCfg.allowBundleRebuild !== false) {
    try {
      const bStat = fs.lstatSync(paths.bundlePath);
      if (bStat.isSymbolicLink()) throw new Error('Target bundle path is a symlink');
    } catch (err) {
      if (err && err.code !== 'ENOENT') {
        emitResult({
          ok: false,
          botId: 'release-pack-sync',
          mode,
          startedAt,
          finishedAt: new Date().toISOString(),
          durationMs: Date.now() - startMs,
          summary: `Bundle path check failed: ${err.message}`,
          checks: [{ id: 'bundleRebuild', status: 'FAIL', detail: err.message }],
          metrics: {},
          estimatedTokensSaved: 0,
        });
      }
    }
    const tmpBundle = `${paths.bundlePath}.tmp.${process.pid}.${crypto.randomBytes(4).toString('hex')}`;
    const tarRes = await execSafeAsync(
      'git',
      ['-C', paths.orchRepo, 'archive', '--format=tar.gz', '-o', tmpBundle, 'HEAD'],
      { cwd: path.dirname(paths.bundlePath), timeoutMs: 30000 }
    );
    if (!tarRes.ok) {
      try { fs.unlinkSync(tmpBundle); } catch {}
      checks.push({ id: 'bundleRebuild', status: 'FAIL', detail: scrubSecrets(tarRes.stderr || `exit=${tarRes.code}`) });
    } else {
      try {
        fs.renameSync(tmpBundle, paths.bundlePath);
        checks.push({ id: 'bundleRebuild', status: 'PASS', detail: `Rebuilt ${path.basename(paths.bundlePath)} from HEAD` });
      } catch (err) {
        try { fs.unlinkSync(tmpBundle); } catch {}
        checks.push({ id: 'bundleRebuild', status: 'FAIL', detail: scrubSecrets(err?.message || 'rename_failed') });
      }
    }
  } else {
    checks.push({ id: 'bundleRebuild', status: 'SKIP', detail: 'Disabled via allowBundleRebuild=false' });
  }

  if (botCfg.allowFleetBroadcast !== false) {
    const pushScript = path.join(paths.orchRepo, 'bin', 'architecture-push');
    if (fs.existsSync(pushScript)) {
      const pushRes = await execSafeAsync('bash', [pushScript], { cwd: paths.orchRepo, timeoutMs: 30000 });
      metrics.pushOutputTail = tailLines(`${pushRes.stdout}\n${pushRes.stderr}`, botCfg.maxLogLines || 80);
      checks.push({
        id: 'fleetBroadcast',
        status: pushRes.ok ? 'PASS' : 'FAIL',
        detail: pushRes.ok ? 'SSE architecture-push succeeded' : `exit=${pushRes.code}`,
      });
    } else {
      checks.push({ id: 'fleetBroadcast', status: 'FAIL', detail: 'architecture-push script missing' });
    }
  } else {
    checks.push({ id: 'fleetBroadcast', status: 'SKIP', detail: 'Disabled via allowFleetBroadcast=false' });
  }
}

// Always run full read-only audit telemetry
function gitSnapshot(repoDir) {
  const head = execSafeSync('git', ['rev-parse', 'HEAD'], { cwd: repoDir });
  const branch = execSafeSync('git', ['rev-parse', '--abbrev-ref', 'HEAD'], { cwd: repoDir });
  const ct = execSafeSync('git', ['show', '-s', '--format=%ct', 'HEAD'], { cwd: repoDir });
  const dirty = execSafeSync('git', ['status', '--porcelain'], { cwd: repoDir });
  const dirtyLines = dirty.ok ? dirty.stdout.split(/\r?\n/).filter(Boolean) : [];
  return {
    head: head.ok ? head.stdout.trim() : null,
    branch: branch.ok ? branch.stdout.trim() : null,
    commitEpochSec: ct.ok ? Number(ct.stdout.trim()) || 0 : 0,
    dirtyCount: dirtyLines.length,
  };
}

const msgGit = gitSnapshot(paths.repoRoot);
const orchGit = gitSnapshot(paths.orchRepo);
metrics.git = {
  messagingAgent: { branch: msgGit.branch, head: (msgGit.head || '').slice(0, 8), dirtyCount: msgGit.dirtyCount },
  orchestrator: { branch: orchGit.branch, head: (orchGit.head || '').slice(0, 8), dirtyCount: orchGit.dirtyCount },
};
checks.push({
  id: 'gitWorktrees',
  status: msgGit.head && orchGit.head ? (msgGit.dirtyCount > 0 || orchGit.dirtyCount > 0 ? 'WARN' : 'PASS') : 'FAIL',
  detail: `messaging-agent@${(msgGit.head || 'none').slice(0, 8)} (dirty=${msgGit.dirtyCount}), orchestrator@${(orchGit.head || 'none').slice(0, 8)} (dirty=${orchGit.dirtyCount})`,
});

// 4-mirror model-routing.json byte equality & schema check
const mirrorPaths = [
  path.join(paths.repoRoot, '.agents', 'config', 'model-routing.json'),
  path.join(paths.orchRepo, 'workspace-template', '.agents', 'config', 'model-routing.json'),
  path.join(paths.orchRepo, 'global', 'gemini', 'config', 'model-routing.json'),
  path.join(paths.configDir, 'model-routing.json'),
];
const hashes = new Set();
const schemas = new Set();
const missingMirrors = [];
for (const mp of mirrorPaths) {
  if (!fs.existsSync(mp)) {
    missingMirrors.push(path.basename(mp));
    continue;
  }
  const h = sha256FileNoSymlink(mp);
  const parsed = readJsonNoSymlink(mp);
  if (h) hashes.add(h);
  if (parsed.ok && parsed.data?.schema_version) schemas.add(String(parsed.data.schema_version));
}
const mirrorStatus = missingMirrors.length === 0 && hashes.size === 1 && schemas.size === 1 ? 'PASS' : 'FAIL';
const schemaVer = Array.from(schemas)[0] || 'unknown';
checks.push({
  id: 'modelRoutingMirrors',
  status: mirrorStatus,
  detail:
    mirrorStatus === 'PASS'
      ? `4/4 mirrors byte-identical at schema ${schemaVer}`
      : `Mismatch: uniqueHashes=${hashes.size}, schemas=${Array.from(schemas).join(',')}, missing=${missingMirrors.join(',')}`,
});
metrics.schemaVersion = schemaVer;

// Bundle freshness check
let bundleStatus = 'FAIL';
let bundleDetail = 'Bundle tarball missing';
try {
  const st = fs.lstatSync(paths.bundlePath);
  if (st.isSymbolicLink() || !st.isFile()) {
    bundleDetail = 'Bundle path is not a regular file';
  } else if (st.size <= 0) {
    bundleDetail = 'Bundle tarball is 0 bytes';
  } else {
    const mtimeSec = Math.floor(st.mtimeMs / 1000);
    const fresh = !orchGit.commitEpochSec || mtimeSec >= orchGit.commitEpochSec;
    bundleStatus = fresh ? 'PASS' : 'WARN';
    bundleDetail = `${Math.round(st.size / 1024)} KB, fresh=${fresh}`;
    metrics.bundleKb = Math.round(st.size / 1024);
  }
} catch {}
checks.push({ id: 'bundleFreshness', status: bundleStatus, detail: bundleDetail });

// Fleet Hub commit alignment
const hubRes = await httpGetJson(paths.fleetHealthUrl, { timeoutMs: 2500 });
const hubAligned = Boolean(
  hubRes.ok && hubRes.data?.latestCommit && orchGit.head && hubRes.data.latestCommit === orchGit.head
);
checks.push({
  id: 'hubCommitAlignment',
  status: hubRes.ok ? (hubAligned ? 'PASS' : 'WARN') : 'FAIL',
  detail: hubRes.ok
    ? `Hub=${String(hubRes.data.latestCommit || '').slice(0, 8)} (${hubRes.data.schemaVersion}) vs Repo=${(orchGit.head || '').slice(0, 8)}`
    : `Hub HTTP ${hubRes.status}`,
});

// Read-only Gatekeeper status
const gatesCheck = verifyGatesReadOnly(paths.repoRoot);
checks.push({ id: 'gatekeeperStatus', ...gatesCheck });

const failCount = checks.filter((c) => c.status === 'FAIL').length;
const warnCount = checks.filter((c) => c.status === 'WARN').length;
const passCount = checks.filter((c) => c.status === 'PASS').length;

emitResult({
  ok: failCount === 0,
  botId: 'release-pack-sync',
  mode,
  startedAt,
  finishedAt: new Date().toISOString(),
  durationMs: Date.now() - startMs,
  summary: `${passCount} PASS, ${warnCount} WARN, ${failCount} FAIL`,
  checks,
  metrics,
  estimatedTokensSaved: 15000,
});
