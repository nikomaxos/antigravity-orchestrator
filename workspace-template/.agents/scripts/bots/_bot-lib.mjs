#!/usr/bin/env node
// Shared utilities for Pool 0 deterministic offload bots (zero LLM tokens, zero Gatekeeper bypass).
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import http from 'node:http';
import https from 'node:https';
import crypto from 'node:crypto';
import { execFile, execFileSync, spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';

export const ALLOWED_SERVICES = Object.freeze([
  'admin-panel',
  'platform-docs',
  'core-service',
  'routing-engine',
  'billing-service',
  'pricing-service',
  'smpp-clients-server',
  'smpp-gateway',
  'rcs-mautrix',
  'ai-service',
  'security-service',
  'device-gateway',
  'deploy-agent',
]);

export function resolvePaths() {
  const userHome = process.env.HOME || os.homedir() || '/home/nick';
  const scriptDir = path.dirname(fileURLToPath(import.meta.url));
  const repoRoot = path.resolve(process.env.AGY_WORKSPACE_DIR || path.resolve(scriptDir, '../../..'));
  const orchRepo = path.resolve(
    process.env.AGY_ORCHESTRATOR_REPO_DIR || path.join(userHome, 'Development', 'antigravity-orchestrator')
  );
  const configDir = path.join(userHome, '.gemini', 'config');
  const cacheDir = path.join(userHome, '.gemini', 'cache');
  const botsConfigFile = process.env.AGY_BOTS_CONFIG_FILE || path.join(configDir, 'offload-bots.json');
  const localRoutingFile = process.env.AGY_LOCAL_ROUTING_FILE || path.join(configDir, 'model-routing.local.json');
  const quotaFile = process.env.AGY_GEMINI_QUOTA_FILE || path.join(configDir, 'gemini-quota.json');
  const cooldownsFile = process.env.AGY_COOLDOWNS_FILE || path.join(cacheDir, 'pool-cooldowns.json');
  const bundlePath = process.env.AGY_BUNDLE_PATH || path.join(userHome, 'Development', 'antigravity-orchestrator-bundle.tar.gz');
  const gatekeeperHealthUrl = process.env.AGY_GATEKEEPER_HEALTH_URL || 'http://127.0.0.1:18099/api/gatekeeper/health';
  const fleetHealthUrl = process.env.AGY_FLEET_HEALTH_URL || 'http://127.0.0.1:18100/api/agy-fleet/health';
  const backendBaseUrl = (process.env.AGY_BACKEND_BASE_URL || 'http://127.0.0.1:8081').replace(/\/+$/, '');
  return {
    userHome,
    scriptDir,
    repoRoot,
    orchRepo,
    configDir,
    cacheDir,
    botsConfigFile,
    localRoutingFile,
    quotaFile,
    cooldownsFile,
    bundlePath,
    gatekeeperHealthUrl,
    fleetHealthUrl,
    backendBaseUrl,
  };
}

export function scrubSecrets(text) {
  let out = String(text || '');
  out = out.replace(/Bearer\s+[A-Za-z0-9._~+/-]+=*/gi, 'Bearer <REDACTED>');
  out = out.replace(/(fleetToken|webhookSecret|password|secret|apiKey|token)\s*[:=]\s*["']?[A-Za-z0-9._~+/=-]{8,}["']?/gi, '$1=<REDACTED>');
  return out;
}

export function tailLines(text, maxLines = 80) {
  const limit = Math.max(10, Math.min(200, Number(maxLines) || 80));
  const lines = scrubSecrets(text).split(/\r?\n/);
  if (lines.length <= limit) return lines.join('\n').trim();
  return `[... ${lines.length - limit} earlier line(s) omitted ...]\n` + lines.slice(-limit).join('\n').trim();
}

export function readJsonNoSymlink(filePath) {
  try {
    const st = fs.lstatSync(filePath);
    if (st.isSymbolicLink()) return { ok: false, error: 'symlink_rejected', data: null };
    if (!st.isFile()) return { ok: false, error: 'not_a_file', data: null };
    const raw = fs.readFileSync(filePath, 'utf8').replace(/^\uFEFF/, '');
    return { ok: true, error: null, data: JSON.parse(raw) };
  } catch (err) {
    if (err && err.code === 'ENOENT') return { ok: false, error: 'missing', data: null };
    return { ok: false, error: err?.message || 'read_error', data: null };
  }
}

export function defaultBotsConfig() {
  return {
    schemaVersion: '2026.11.6',
    environment: 'STAGING',
    updatedAt: null,
    updatedBy: 'default',
    retention: { maxRunsPerBot: 25 },
    bots: {
      'ops-preflight': {
        enabled: true,
        schedule: 'manual',
        timeoutSec: 45,
        maxLogLines: 80,
        includeBackendSummary: true,
        includeCooldowns: true,
        includeQuotaMeter: true,
      },
      'staging-deploy-verify': {
        enabled: true,
        schedule: 'manual',
        timeoutSec: 300,
        maxLogLines: 80,
        autoVerifyHelp: true,
        allowedServices: [...ALLOWED_SERVICES],
      },
      'release-pack-sync': {
        enabled: true,
        schedule: 'manual',
        timeoutSec: 120,
        maxLogLines: 80,
        strictCleanWorktree: true,
        allowBundleRebuild: true,
        allowFleetBroadcast: true,
      },
    },
  };
}

export function loadBotsConfig(botsConfigFile) {
  const def = defaultBotsConfig();
  const res = readJsonNoSymlink(botsConfigFile);
  if (!res.ok || !res.data || typeof res.data !== 'object') return def;
  const loadedBots = res.data.bots && typeof res.data.bots === 'object' ? res.data.bots : {};
  return {
    ...def,
    ...res.data,
    retention: { ...def.retention, ...(res.data.retention || {}) },
    bots: {
      'ops-preflight': { ...def.bots['ops-preflight'], ...(loadedBots['ops-preflight'] || {}) },
      'staging-deploy-verify': { ...def.bots['staging-deploy-verify'], ...(loadedBots['staging-deploy-verify'] || {}) },
      'release-pack-sync': { ...def.bots['release-pack-sync'], ...(loadedBots['release-pack-sync'] || {}) },
    },
  };
}

export function parseArgs(argv) {
  const opts = { mode: null, services: [] };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === '--mode' && i + 1 < argv.length) {
      opts.mode = String(argv[++i]).trim();
    } else if (arg.startsWith('--mode=')) {
      opts.mode = arg.slice('--mode='.length).trim();
    } else if (arg === '--services' && i + 1 < argv.length) {
      opts.services = String(argv[++i])
        .split(',')
        .map((s) => s.trim())
        .filter(Boolean);
    } else if (arg.startsWith('--services=')) {
      opts.services = arg
        .slice('--services='.length)
        .split(',')
        .map((s) => s.trim())
        .filter(Boolean);
    }
  }
  return opts;
}

export function execSafeSync(cmd, args, { cwd, timeoutMs = 15000, env } = {}) {
  try {
    const stdout = execFileSync(cmd, args, {
      cwd,
      timeout: timeoutMs,
      encoding: 'utf8',
      shell: false,
      env: env || process.env,
      maxBuffer: 4 * 1024 * 1024,
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    return { ok: true, code: 0, stdout: String(stdout || ''), stderr: '' };
  } catch (err) {
    return {
      ok: false,
      code: typeof err?.status === 'number' ? err.status : 1,
      stdout: String(err?.stdout || ''),
      stderr: String(err?.stderr || err?.message || ''),
    };
  }
}

export function execSafeAsync(cmd, args, { cwd, timeoutMs = 120000, env } = {}) {
  return new Promise((resolve) => {
    execFile(
      cmd,
      args,
      {
        cwd,
        timeout: timeoutMs,
        encoding: 'utf8',
        shell: false,
        env: env || process.env,
        maxBuffer: 8 * 1024 * 1024,
      },
      (err, stdout, stderr) => {
        if (!err) {
          resolve({ ok: true, code: 0, stdout: String(stdout || ''), stderr: String(stderr || '') });
          return;
        }
        resolve({
          ok: false,
          code: typeof err.code === 'number' ? err.code : 1,
          stdout: String(stdout || ''),
          stderr: String(stderr || err.message || ''),
        });
      }
    );
  });
}

export function execGroupAsync(cmd, args, { cwd, timeoutMs = 120000, env } = {}) {
  return new Promise((resolve) => {
    const child = spawn(cmd, args, {
      cwd,
      env: env || process.env,
      shell: false,
      detached: true,
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    const stdoutChunks = [];
    const stderrChunks = [];
    let totalBytes = 0;
    const maxBytes = 8 * 1024 * 1024;
    let timedOut = false;

    const killGroup = (sig) => {
      try {
        process.kill(-child.pid, sig);
      } catch {
        try {
          child.kill(sig);
        } catch {}
      }
    };

    const timer = setTimeout(() => {
      timedOut = true;
      killGroup('SIGTERM');
      setTimeout(() => killGroup('SIGKILL'), 1500).unref();
    }, timeoutMs);

    child.stdout.on('data', (c) => {
      totalBytes += c.length;
      if (totalBytes <= maxBytes) stdoutChunks.push(c);
    });
    child.stderr.on('data', (c) => {
      totalBytes += c.length;
      if (totalBytes <= maxBytes) stderrChunks.push(c);
    });
    child.on('error', (err) => {
      clearTimeout(timer);
      resolve({
        ok: false,
        code: 1,
        timedOut,
        stdout: Buffer.concat(stdoutChunks).toString('utf8'),
        stderr: String(err?.message || 'spawn_error'),
      });
    });
    child.on('close', (code) => {
      clearTimeout(timer);
      resolve({
        ok: !timedOut && code === 0,
        code: timedOut ? 124 : typeof code === 'number' ? code : 1,
        timedOut,
        stdout: Buffer.concat(stdoutChunks).toString('utf8'),
        stderr: Buffer.concat(stderrChunks).toString('utf8') + (timedOut ? `\n[timeout after ${timeoutMs}ms]` : ''),
      });
    });
  });
}

export function httpGetJson(urlStr, { timeoutMs = 3000, headers = {} } = {}) {
  return new Promise((resolve) => {
    try {
      const target = new URL(urlStr);
      if (target.protocol !== 'http:' && target.protocol !== 'https:') {
        resolve({ ok: false, status: 0, data: null, raw: `unsupported_protocol:${target.protocol}` });
        return;
      }
      const client = target.protocol === 'https:' ? https : http;
      const req = client.request(
        {
          hostname: target.hostname,
          port: target.port || (target.protocol === 'https:' ? 443 : 80),
          path: target.pathname + target.search,
          method: 'GET',
          headers: { Accept: 'application/json', ...headers },
          timeout: timeoutMs,
        },
        (res) => {
          const chunks = [];
          let total = 0;
          res.on('data', (c) => {
            total += c.length;
            if (total <= 1024 * 1024) chunks.push(c);
          });
          res.on('end', () => {
            const raw = Buffer.concat(chunks).toString('utf8');
            let parsed = null;
            try {
              parsed = JSON.parse(raw);
            } catch {}
            resolve({
              ok: res.statusCode >= 200 && res.statusCode < 300,
              status: res.statusCode || 0,
              data: parsed,
              raw,
            });
          });
        }
      );
      req.on('timeout', () => {
        req.destroy();
        resolve({ ok: false, status: 0, data: null, raw: 'timeout' });
      });
      req.on('error', (err) => {
        resolve({ ok: false, status: 0, data: null, raw: err?.message || 'network_error' });
      });
      req.end();
    } catch (err) {
      resolve({ ok: false, status: 0, data: null, raw: err?.message || 'invalid_url' });
    }
  });
}

export function checkDockerCompose(repoRoot, timeoutMs = 10000) {
  const res = execSafeSync('docker', ['compose', 'ps', '--format', 'json'], { cwd: repoRoot, timeoutMs });
  if (!res.ok) {
    return {
      ok: false,
      check: { id: 'dockerContainers', status: 'FAIL', detail: scrubSecrets(res.stderr || res.stdout || 'docker compose ps failed') },
      metrics: { total: 0, running: 0, unhealthy: 0, stopped: 0 },
    };
  }
  const containers = res.stdout
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter(Boolean)
    .flatMap((line) => {
      try {
        const parsed = JSON.parse(line);
        return Array.isArray(parsed) ? parsed : [parsed];
      } catch {
        return [];
      }
    })
    .filter((item) => item && typeof item === 'object');

  let running = 0;
  let unhealthy = 0;
  let stopped = 0;
  const problemNames = [];
  for (const c of containers) {
    const state = String(c.State || '').toLowerCase();
    const health = String(c.Health || '').toLowerCase();
    if (state === 'running') running += 1;
    else {
      stopped += 1;
      problemNames.push(`${c.Service || c.Name}:${state || 'unknown'}`);
    }
    if (health === 'unhealthy') {
      unhealthy += 1;
      problemNames.push(`${c.Service || c.Name}:unhealthy`);
    }
  }
  const status = unhealthy > 0 ? 'FAIL' : stopped > 0 ? 'WARN' : containers.length > 0 ? 'PASS' : 'WARN';
  const detail =
    problemNames.length > 0
      ? `${running}/${containers.length} running; issues: ${problemNames.slice(0, 6).join(', ')}`
      : `${running}/${containers.length} running cleanly`;
  return {
    ok: status !== 'FAIL',
    check: { id: 'dockerContainers', status, detail },
    metrics: { total: containers.length, running, unhealthy, stopped },
  };
}

export function verifyGatesReadOnly(repoRoot) {
  const scriptPath = path.join(repoRoot, '.agents', 'scripts', 'verify-gates.sh');
  if (!fs.existsSync(scriptPath)) {
    return { status: 'SKIP', detail: 'verify-gates.sh not found in workspace' };
  }
  const res = execSafeSync('bash', [scriptPath], { cwd: repoRoot, timeoutMs: 8000 });
  const msg = scrubSecrets((res.stdout || res.stderr || '').trim().split(/\r?\n/).pop() || '');
  return {
    status: res.ok ? 'PASS' : 'WARN',
    detail: msg || (res.ok ? 'All signed gates verified' : 'Pending or unsigned gates'),
  };
}

export function sha256FileNoSymlink(filePath) {
  const st = fs.lstatSync(filePath);
  if (st.isSymbolicLink() || !st.isFile()) return null;
  return crypto.createHash('sha256').update(fs.readFileSync(filePath)).digest('hex');
}

export function emitResult(result) {
  process.stdout.write(JSON.stringify(result, null, 2) + '\n');
  process.exit(result.ok ? 0 : 1);
}
