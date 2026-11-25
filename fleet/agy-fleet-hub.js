#!/usr/bin/env node
// =============================================================================
// Antigravity Event-Driven Fleet Push Hub (`agy-fleet-hub.js`)
// =============================================================================
// Zero-dependency HTTP/SSE control plane daemon running on DevBox (0.0.0.0:18100).
// - Receives GitHub push webhooks (HMAC-SHA256) and CLI/Admin publish triggers
// - Broadcasts instant SSE `sync` events to all connected workstations
// - Tracks online status, synced commit SHA, schema_version, and Gatekeeper health
// - Serves authenticated bootstrap scripts & setup bundles for:
//     * Nick Laptop — Windows 11 (Κοπανός / Mobile Personal)
//     * Soti-Laptop — Windows 11 Pro (Ωραιόκαστρο)
//     * Omarchy Linux / Arch (Κοπανός Ημαθίας)
// =============================================================================
'use strict';

const http = require('http');
const fs = require('fs');
const path = require('path');
const os = require('os');
const crypto = require('crypto');
const { execFileSync, execFile } = require('child_process');

const HOST = process.env.AGY_FLEET_HOST || '0.0.0.0';
const PORT = process.env.AGY_FLEET_PORT !== undefined ? Number(process.env.AGY_FLEET_PORT) : 18100;
const USER_HOME = process.env.HOME || os.homedir() || '/home/nick';
const CONFIG_DIR = process.env.AGY_FLEET_CONFIG_DIR || path.join(USER_HOME, '.config', 'agy-fleet');
const DATA_DIR = process.env.AGY_FLEET_DATA_DIR || path.join(USER_HOME, '.local', 'share', 'agy-fleet');
const CONFIG_FILE = path.join(CONFIG_DIR, 'hub-config.json');
const NODES_FILE = path.join(DATA_DIR, 'nodes.json');
const ADMIN_VERIFY_URL = process.env.AGY_FLEET_ADMIN_VERIFY_URL || 'http://127.0.0.1:8081/api/users/me';
const ABOUT_VERIFY_URL = process.env.AGY_ABOUT_URL || 'http://127.0.0.1:8081/api/system/about';
const ABOUT_CACHE_TTL_MS = Number(process.env.AGY_ABOUT_CACHE_MS ?? 15000);
const WORKSPACE_DIR = path.resolve(process.env.AGY_WORKSPACE_DIR || path.join(USER_HOME, 'Development', 'messaging-agent'));
const GEMINI_CONFIG_DIR = path.join(USER_HOME, '.gemini', 'config');
const BOTS_CONFIG_FILE = process.env.AGY_BOTS_CONFIG_FILE || path.join(GEMINI_CONFIG_DIR, 'offload-bots.json');
const BOTS_RUNS_FILE = process.env.AGY_BOTS_RUNS_FILE || path.join(DATA_DIR, 'bot-runs.json');
const LOCAL_ROUTING_FILE = process.env.AGY_LOCAL_ROUTING_FILE || path.join(GEMINI_CONFIG_DIR, 'model-routing.local.json');
const COOLDOWNS_FILE = process.env.AGY_COOLDOWNS_FILE || path.join(USER_HOME, '.gemini', 'cache', 'pool-cooldowns.json');
const GEMINI_QUOTA_FILE = process.env.AGY_GEMINI_QUOTA_FILE || path.join(GEMINI_CONFIG_DIR, 'gemini-quota.json');
const STARTED_AT = Date.now();
const MAX_BODY_BYTES = 2 * 1024 * 1024;
const HEARTBEAT_MS = 25000;

const CANONICAL_PROFILES = {
  devbox: {
    nodeId: 'devbox',
    label: 'DevBox (Staging Primary)',
    location: 'Hetzner Cloud (10.10.10.96)',
    os: 'Ubuntu 24.04 Linux',
    platform: 'linux',
    expectedProfile: 'devbox',
  },
  'nick-laptop': {
    nodeId: 'nick-laptop',
    label: 'Nick Laptop (Windows 11)',
    location: 'Κοπανός / Mobile (Personal)',
    os: 'Windows 11',
    platform: 'win32',
    expectedProfile: 'nick-laptop',
  },
  'oraiokastro-win11': {
    nodeId: 'oraiokastro-win11',
    label: 'Soti-Laptop (Windows 11 Pro)',
    location: 'Ωραιόκαστρο',
    os: 'Windows 11 Pro',
    platform: 'win32',
    expectedProfile: 'oraiokastro-win11',
  },
  'kopanos-omarchy': {
    nodeId: 'kopanos-omarchy',
    label: 'Omarchy Workstation',
    location: 'Κοπανός Ημαθίας',
    os: 'Omarchy Linux (Arch / Hyprland)',
    platform: 'linux',
    expectedProfile: 'kopanos-omarchy',
  },
};

function ensureDir(dirPath, mode = 0o700) {
  fs.mkdirSync(dirPath, { recursive: true, mode });
}

function writePrivateJson(filePath, data) {
  ensureDir(path.dirname(filePath), 0o700);
  const tmpPath = `${filePath}.tmp.${process.pid}`;
  fs.writeFileSync(tmpPath, JSON.stringify(data, null, 2) + '\n', { mode: 0o600 });
  fs.renameSync(tmpPath, filePath);
  try {
    fs.chmodSync(filePath, 0o600);
  } catch {}
}

function loadOrCreateConfig() {
  ensureDir(CONFIG_DIR, 0o700);
  const defaults = {
    fleetToken: crypto.randomBytes(32).toString('hex'),
    webhookSecret: crypto.randomBytes(32).toString('hex'),
    publicHubUrl: process.env.AGY_FLEET_PUBLIC_URL || 'https://staging-messaging-agent.globalnetservices.net/api/agy-fleet',
    repoUrl: 'https://github.com/nikomaxos/antigravity-orchestrator.git',
    repoDir: process.env.AGY_ORCHESTRATOR_REPO_DIR || path.join(USER_HOME, 'Development', 'antigravity-orchestrator'),
  };

  if (fs.existsSync(CONFIG_FILE)) {
    try {
      const parsed = JSON.parse(fs.readFileSync(CONFIG_FILE, 'utf8'));
      const merged = {
        fleetToken: parsed.fleetToken || defaults.fleetToken,
        webhookSecret: parsed.webhookSecret || defaults.webhookSecret,
        publicHubUrl: parsed.publicHubUrl || defaults.publicHubUrl,
        repoUrl: parsed.repoUrl || defaults.repoUrl,
        repoDir: parsed.repoDir || defaults.repoDir,
      };
      if (!parsed.fleetToken || !parsed.webhookSecret || !parsed.publicHubUrl) {
        writePrivateJson(CONFIG_FILE, merged);
      }
      return merged;
    } catch {
      // Corrupt config fallback
    }
  }
  writePrivateJson(CONFIG_FILE, defaults);
  return defaults;
}

let hubConfig = loadOrCreateConfig();

function loadOrInitNodes() {
  ensureDir(DATA_DIR, 0o700);
  const nodes = {};
  if (fs.existsSync(NODES_FILE)) {
    try {
      const existing = JSON.parse(fs.readFileSync(NODES_FILE, 'utf8'));
      if (existing && typeof existing === 'object') {
        Object.assign(nodes, existing);
      }
    } catch {}
  }
  let changed = false;
  for (const [id, profile] of Object.entries(CANONICAL_PROFILES)) {
    if (!nodes[id]) {
      nodes[id] = {
        nodeId: id,
        label: profile.label,
        location: profile.location,
        os: profile.os,
        platform: profile.platform,
        expectedProfile: profile.expectedProfile,
        hostname: null,
        commit: null,
        schemaVersion: null,
        online: false,
        connectedSince: null,
        lastSeenAt: null,
        lastSyncAt: null,
        lastSyncStatus: 'PENDING_INSTALL',
        lastSyncDurationMs: null,
        workspacesSynced: 0,
        gatekeeperHealthy: null,
        clientIp: null,
      };
      changed = true;
    } else {
      // Ensure canonical labels stay current while preserving live state
      nodes[id].label = nodes[id].label || profile.label;
      nodes[id].location = nodes[id].location || profile.location;
      nodes[id].os = nodes[id].os || profile.os;
      nodes[id].platform = nodes[id].platform || profile.platform;
      nodes[id].expectedProfile = profile.expectedProfile;
      if (nodes[id].online) {
        // On hub boot, no SSE sockets are attached yet
        nodes[id].online = false;
        changed = true;
      }
    }
  }
  if (changed || !fs.existsSync(NODES_FILE)) {
    writePrivateJson(NODES_FILE, nodes);
  }
  return nodes;
}

const nodesState = loadOrInitNodes();
const sseClients = new Map(); // clientId -> { res, nodeId, connectedAt }
const pendingAckWaiters = new Map(); // commit -> Set<{ resolve, timer }>

let hubState = {
  latestCommit: null,
  schemaVersion: null,
  lastPushAt: null,
  lastWebhookAt: null,
  lastWebhookEvent: null,
};

function readRepoHeadAndSchema() {
  let commit = hubState.latestCommit;
  let schemaVersion = hubState.schemaVersion;
  let updatedAt = null;
  try {
    commit = execFileSync('git', ['-C', hubConfig.repoDir, 'rev-parse', 'HEAD'], { encoding: 'utf8', timeout: 3000 }).trim();
  } catch {}
  try {
    const routingPath = path.join(hubConfig.repoDir, 'global', 'gemini', 'config', 'model-routing.json');
    if (fs.existsSync(routingPath)) {
      const parsed = JSON.parse(fs.readFileSync(routingPath, 'utf8'));
      if (parsed.schema_version) schemaVersion = String(parsed.schema_version);
      if (parsed.updated_at) updatedAt = String(parsed.updated_at);
    }
  } catch {}
  hubState.latestCommit = commit;
  hubState.schemaVersion = schemaVersion;
  return { commit, schemaVersion, updatedAt };
}

readRepoHeadAndSchema();

function persistNodes() {
  writePrivateJson(NODES_FILE, nodesState);
}

function resolveCanonicalNodeId(rawNodeId, rawOs, rawHostname) {
  if (rawNodeId && CANONICAL_PROFILES[rawNodeId]) return rawNodeId;
  if (rawNodeId && nodesState[rawNodeId]) return rawNodeId;
  const hostLow = String(rawHostname || '').toLowerCase();
  const osLow = String(rawOs || '').toLowerCase();
  if (hostLow.includes('soti') || hostLow.includes('oraio')) return 'oraiokastro-win11';
  if (hostLow.includes('nick') || hostLow.includes('parda') || hostLow.includes('lenovo')) return 'nick-laptop';
  if (osLow.includes('omarchy') || osLow.includes('arch') || hostLow.includes('omarchy') || hostLow.includes('kopanos')) {
    return 'kopanos-omarchy';
  }
  if (hostLow.includes('devbox') || rawNodeId === 'devbox') return 'devbox';
  return rawNodeId || `node-${crypto.randomBytes(4).toString('hex')}`;
}

function resetNodeToPending(nodeId) {
  const profile = CANONICAL_PROFILES[nodeId];
  if (!profile) return;
  nodesState[nodeId] = {
    nodeId,
    label: profile.label,
    location: profile.location,
    os: profile.os,
    platform: profile.platform,
    expectedProfile: profile.expectedProfile,
    hostname: null,
    commit: null,
    schemaVersion: null,
    online: false,
    connectedSince: null,
    lastSeenAt: null,
    lastSyncAt: null,
    lastSyncStatus: 'PENDING_INSTALL',
    lastSyncDurationMs: null,
    workspacesSynced: 0,
    gatekeeperHealthy: null,
    clientIp: null,
  };
}

function closeStreamsForNode(nodeId) {
  for (const [cid, client] of Array.from(sseClients.entries())) {
    if (client.nodeId === nodeId) {
      try {
        client.res.end();
      } catch {}
      sseClients.delete(cid);
    }
  }
}

function reconcileDuplicateHostname(activeNodeId, hostname, previousNodeId = null) {
  const hostNorm = String(hostname || '').trim().toLowerCase();
  let changed = false;

  if (previousNodeId && previousNodeId !== activeNodeId && CANONICAL_PROFILES[previousNodeId]) {
    const prevNode = nodesState[previousNodeId];
    const hasLiveStream = Array.from(sseClients.values()).some((c) => c.nodeId === previousNodeId);
    const sameHost = Boolean(prevNode?.hostname && hostNorm && prevNode.hostname.trim().toLowerCase() === hostNorm);
    if (!hasLiveStream || sameHost || !prevNode?.hostname) {
      if (hasLiveStream) closeStreamsForNode(previousNodeId);
      resetNodeToPending(previousNodeId);
      changed = true;
    }
  }

  if (hostNorm) {
    for (const [otherId, otherNode] of Object.entries(nodesState)) {
      if (otherId === activeNodeId) continue;
      if (otherNode.hostname && String(otherNode.hostname).trim().toLowerCase() === hostNorm) {
        closeStreamsForNode(otherId);
        if (CANONICAL_PROFILES[otherId]) {
          resetNodeToPending(otherId);
        } else {
          delete nodesState[otherId];
        }
        changed = true;
      }
    }
  }
  return changed;
}

function getOrderedNodes() {
  const connectedCounts = new Map();
  for (const client of sseClients.values()) {
    connectedCounts.set(client.nodeId, (connectedCounts.get(client.nodeId) || 0) + 1);
  }
  const orderedIds = ['devbox', 'nick-laptop', 'oraiokastro-win11', 'kopanos-omarchy'];
  const extraIds = Object.keys(nodesState).filter((id) => !orderedIds.includes(id)).sort();
  return [...orderedIds, ...extraIds]
    .filter((id) => Boolean(nodesState[id]))
    .map((id) => {
      const n = nodesState[id];
      const streamCount = connectedCounts.get(id) || 0;
      return {
        ...n,
        online: streamCount > 0,
        activeStreams: streamCount,
        inSync: Boolean(n.commit && hubState.latestCommit && n.commit === hubState.latestCommit),
      };
    });
}

function constantTimeTokenEqual(a, b) {
  if (typeof a !== 'string' || typeof b !== 'string' || !a || !b) return false;
  const da = crypto.createHash('sha256').update(a, 'utf8').digest();
  const db = crypto.createHash('sha256').update(b, 'utf8').digest();
  return crypto.timingSafeEqual(da, db);
}

function extractBearer(req) {
  const auth = req.headers.authorization || '';
  if (auth.startsWith('Bearer ')) return auth.slice(7).trim();
  return '';
}

function isFleetAuthorized(req, urlObj) {
  const token = extractBearer(req) || String(req.headers['x-fleet-token'] || '').trim() || urlObj.searchParams.get('token') || '';
  return constantTimeTokenEqual(token, hubConfig.fleetToken);
}

function verifyAdminJwt(req) {
  return new Promise((resolve) => {
    const token = extractBearer(req);
    if (!token) return resolve({ ok: false, status: 401, reason: 'Missing Authorization Bearer JWT' });

    try {
      const target = new URL(ADMIN_VERIFY_URL);
      const client = target.protocol === 'https:' ? require('https') : http;
      const upstream = client.request(
        {
          hostname: target.hostname,
          port: target.port || (target.protocol === 'https:' ? 443 : 80),
          path: target.pathname + target.search,
          method: 'GET',
          headers: {
            Authorization: `Bearer ${token}`,
            Accept: 'application/json',
          },
          timeout: 5000,
        },
        (res) => {
          let raw = '';
          res.on('data', (chunk) => {
            if (raw.length < 32768) raw += chunk.toString('utf8');
          });
          res.on('end', () => {
            if (res.statusCode !== 200) {
              return resolve({ ok: false, status: 401, reason: `Upstream auth HTTP ${res.statusCode}` });
            }
            try {
              const user = JSON.parse(raw);
              const role = String(user.role || '').toUpperCase();
              if (role === 'SUPER_ADMIN' || role === 'ADMIN') {
                return resolve({ ok: true, user, token });
              }
              return resolve({ ok: false, status: 403, reason: `Insufficient role: ${role}` });
            } catch {
              return resolve({ ok: false, status: 401, reason: 'Invalid auth response JSON' });
            }
          });
        }
      );
      upstream.on('timeout', () => {
        upstream.destroy();
        resolve({ ok: false, status: 401, reason: 'Upstream auth timeout' });
      });
      upstream.on('error', (err) => {
        resolve({ ok: false, status: 401, reason: err.message });
      });
      upstream.end();
    } catch (err) {
      resolve({ ok: false, status: 401, reason: err.message });
    }
  });
}

// =============================================================================
// Pool 0 Deterministic Linux Offload Bots & Local Quota Config (Staging Only)
// =============================================================================
const BOT_ALLOWED_SERVICES = [
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
];

const BOT_CATALOG = {
  'ops-preflight': {
    botId: 'ops-preflight',
    label: 'Ops Preflight Telemetry',
    description: '100% read-only Staging health, Gatekeeper, quota meter, cooldown cache & aggregate modem/SMSC count check (0 LLM tokens).',
    script: 'ops-preflight.mjs',
    modes: ['readonly'],
    defaultMode: 'readonly',
    mutatingModes: [],
    estimatedTokensSaved: 18000,
  },
  'staging-deploy-verify': {
    botId: 'staging-deploy-verify',
    label: 'Staging Deploy & Verify',
    description: 'Inspects pending changed modules, verifies container health, HTTP routes & contextual help coverage (verify), or deploys allowlisted services via deploy-staging.sh.',
    script: 'staging-deploy-verify.mjs',
    modes: ['verify', 'deploy'],
    defaultMode: 'verify',
    mutatingModes: ['deploy'],
    estimatedTokensSaved: 25000,
  },
  'release-pack-sync': {
    botId: 'release-pack-sync',
    label: 'Release Pack & Fleet Sync',
    description: 'Verifies 4-mirror model-routing byte equality, orchestrator tarball freshness & signed gates (audit), or rebuilds bundle & pushes SSE sync cleanly.',
    script: 'release-pack-sync.mjs',
    modes: ['audit', 'sync'],
    defaultMode: 'audit',
    mutatingModes: ['sync'],
    estimatedTokensSaved: 15000,
  },
};

const VALID_BOT_SCHEDULES = new Set(['manual', 'hourly', 'daily']);
const LOCAL_ROUTING_ALLOWLIST = new Set([
  'ctx_hard_limit_tokens',
  'ctx_warn_tokens',
  'warn_threshold_pct',
  'reinject_minutes',
]);

const runningBots = new Map();
let cachedAboutStaging = { confirmedAt: 0, environment: null };

function scrubSensitiveOutput(text) {
  let out = String(text || '');
  out = out.replace(/Bearer\s+[A-Za-z0-9._~+/-]+=*/gi, 'Bearer <REDACTED>');
  out = out.replace(/(fleetToken|webhookSecret|password|secret|apiKey|token)\s*[:=]\s*["']?[A-Za-z0-9._~+/=-]{8,}["']?/gi, '$1=<REDACTED>');
  return out;
}

function readJsonSafeNoSymlink(filePath) {
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

function writePrivateJsonSafe(filePath, data) {
  const dir = path.dirname(filePath);
  ensureDir(dir, 0o700);
  try {
    const st = fs.lstatSync(filePath);
    if (st.isSymbolicLink()) {
      throw new Error(`Refusing to write to symlink target: ${path.basename(filePath)}`);
    }
  } catch (err) {
    if (err && err.code !== 'ENOENT') throw err;
  }
  const tmpPath = `${filePath}.tmp.${process.pid}.${crypto.randomBytes(6).toString('hex')}`;
  fs.writeFileSync(tmpPath, JSON.stringify(data, null, 2) + '\n', { mode: 0o600, flag: 'wx' });
  fs.renameSync(tmpPath, filePath);
  try {
    fs.chmodSync(filePath, 0o600);
  } catch {}
}

function defaultOffloadBotsConfig() {
  return {
    schemaVersion: hubState.schemaVersion || '2026.11.7',
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
        allowedServices: [...BOT_ALLOWED_SERVICES],
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

function loadOffloadBotsConfig() {
  const def = defaultOffloadBotsConfig();
  const res = readJsonSafeNoSymlink(BOTS_CONFIG_FILE);
  if (!res.ok || !res.data || typeof res.data !== 'object') return def;
  const srcBots = res.data.bots && typeof res.data.bots === 'object' ? res.data.bots : {};
  return {
    ...def,
    ...res.data,
    retention: { ...def.retention, ...(res.data.retention || {}) },
    bots: {
      'ops-preflight': { ...def.bots['ops-preflight'], ...(srcBots['ops-preflight'] || {}) },
      'staging-deploy-verify': { ...def.bots['staging-deploy-verify'], ...(srcBots['staging-deploy-verify'] || {}) },
      'release-pack-sync': { ...def.bots['release-pack-sync'], ...(srcBots['release-pack-sync'] || {}) },
    },
  };
}

function loadBotRuns() {
  const res = readJsonSafeNoSymlink(BOTS_RUNS_FILE);
  if (res.ok && Array.isArray(res.data)) return res.data;
  return [];
}

function appendBotRunRecord(run, maxRunsPerBot = 25) {
  const existing = loadBotRuns();
  const next = [run, ...existing];
  const counts = {};
  const pruned = [];
  for (const item of next) {
    if (!item || !item.botId) continue;
    counts[item.botId] = (counts[item.botId] || 0) + 1;
    if (counts[item.botId] <= maxRunsPerBot) {
      pruned.push(item);
    }
  }
  writePrivateJsonSafe(BOTS_RUNS_FILE, pruned.slice(0, 150));
}

function extractRequestHosts(req) {
  const hosts = [];
  for (const raw of [req.headers['x-forwarded-host'], req.headers.host]) {
    if (!raw || typeof raw !== 'string') continue;
    for (const part of raw.split(',')) {
      const clean = part.trim().toLowerCase().replace(/:\d+$/, '');
      if (clean) hosts.push(clean);
    }
  }
  return hosts;
}

function verifyStagingAbout(bearerToken) {
  const now = Date.now();
  if (ABOUT_CACHE_TTL_MS > 0 && cachedAboutStaging.environment === 'STAGING' && now - cachedAboutStaging.confirmedAt < ABOUT_CACHE_TTL_MS) {
    return Promise.resolve({ ok: true, environment: 'STAGING' });
  }
  return new Promise((resolve) => {
    try {
      const target = new URL(ABOUT_VERIFY_URL);
      const client = target.protocol === 'https:' ? require('https') : http;
      const headers = { Accept: 'application/json' };
      if (bearerToken) headers.Authorization = `Bearer ${bearerToken}`;
      const upstream = client.request(
        {
          hostname: target.hostname,
          port: target.port || (target.protocol === 'https:' ? 443 : 80),
          path: target.pathname + target.search,
          method: 'GET',
          headers,
          timeout: 4000,
        },
        (res) => {
          let raw = '';
          res.on('data', (chunk) => {
            if (raw.length < 32768) raw += chunk.toString('utf8');
          });
          res.on('end', () => {
            if (res.statusCode !== 200) {
              return resolve({ ok: false, reason: `Staging verification HTTP ${res.statusCode}` });
            }
            try {
              const parsed = JSON.parse(raw);
              const env = String(parsed.environment || '').toUpperCase();
              if (env === 'STAGING') {
                cachedAboutStaging = { confirmedAt: Date.now(), environment: 'STAGING' };
                return resolve({ ok: true, environment: 'STAGING' });
              }
              cachedAboutStaging = { confirmedAt: 0, environment: env || null };
              return resolve({ ok: false, reason: `Non-staging environment detected: ${env || 'UNKNOWN'}` });
            } catch {
              return resolve({ ok: false, reason: 'Invalid system/about JSON response' });
            }
          });
        }
      );
      upstream.on('timeout', () => {
        upstream.destroy();
        resolve({ ok: false, reason: 'Staging verification timeout' });
      });
      upstream.on('error', (err) => {
        resolve({ ok: false, reason: `Staging verification unreachable: ${err.message}` });
      });
      upstream.end();
    } catch (err) {
      resolve({ ok: false, reason: err.message });
    }
  });
}

async function requireStagingAdmin(req) {
  const runtimeEnv = String(process.env.AGY_FLEET_ENV || 'staging').trim().toLowerCase();
  if (runtimeEnv === 'production') {
    return { ok: false, status: 403, reason: 'Offload Bots and local routing controls are disabled in Production.' };
  }
  const hosts = extractRequestHosts(req);
  if (hosts.includes('messaging-agent.globalnetservices.net')) {
    return { ok: false, status: 403, reason: 'Offload Bots and local routing controls are disabled on Production hostname.' };
  }
  const adminAuth = await verifyAdminJwt(req);
  if (!adminAuth.ok) {
    return { ok: false, status: adminAuth.status || 401, reason: adminAuth.reason || 'Unauthorized' };
  }
  const stageRes = await verifyStagingAbout(adminAuth.token);
  if (!stageRes.ok) {
    return { ok: false, status: 403, reason: stageRes.reason || 'Staging verification failed' };
  }
  return { ok: true, user: adminAuth.user, token: adminAuth.token, environment: 'STAGING' };
}

function readFleetAndLocalRouting() {
  let fleetRouting = {};
  const fleetRoutingPath = path.join(hubConfig.repoDir, 'global', 'gemini', 'config', 'model-routing.json');
  const fleetRes = readJsonSafeNoSymlink(fleetRoutingPath);
  if (fleetRes.ok && fleetRes.data?.gemini_quota_guard) {
    fleetRouting = fleetRes.data.gemini_quota_guard;
  }
  const localRes = readJsonSafeNoSymlink(LOCAL_ROUTING_FILE);
  const localGuard =
    localRes.ok && localRes.data?.gemini_quota_guard && typeof localRes.data.gemini_quota_guard === 'object'
      ? localRes.data.gemini_quota_guard
      : {};
  const fleetDefaults = {
    ctx_hard_limit_tokens: Number(fleetRouting.ctx_hard_limit_tokens ?? 200000),
    ctx_warn_tokens: Number(fleetRouting.ctx_warn_tokens ?? 150000),
    warn_threshold_pct: Number(fleetRouting.warn_threshold_pct ?? 30),
    reinject_minutes: Number(fleetRouting.reinject_minutes ?? 15),
    reserve_threshold_pct: Number(fleetRouting.reserve_threshold_pct ?? 10),
    restore_threshold_pct: Number(fleetRouting.restore_threshold_pct ?? 25),
    auto: fleetRouting.auto !== false,
  };
  const effective = {
    ctx_hard_limit_tokens: Number(localGuard.ctx_hard_limit_tokens ?? fleetDefaults.ctx_hard_limit_tokens),
    ctx_warn_tokens: Number(localGuard.ctx_warn_tokens ?? fleetDefaults.ctx_warn_tokens),
    warn_threshold_pct: Number(localGuard.warn_threshold_pct ?? fleetDefaults.warn_threshold_pct),
    reinject_minutes: Number(localGuard.reinject_minutes ?? fleetDefaults.reinject_minutes),
    reserve_threshold_pct: fleetDefaults.reserve_threshold_pct,
    restore_threshold_pct: fleetDefaults.restore_threshold_pct,
    auto: fleetDefaults.auto,
  };
  return {
    fleetDefaults,
    localOverride: {
      exists: Boolean(localRes.ok),
      error: localRes.ok || localRes.error === 'missing' ? null : localRes.error,
      values: {
        ctx_hard_limit_tokens: localGuard.ctx_hard_limit_tokens ?? null,
        ctx_warn_tokens: localGuard.ctx_warn_tokens ?? null,
        warn_threshold_pct: localGuard.warn_threshold_pct ?? null,
        reinject_minutes: localGuard.reinject_minutes ?? null,
      },
    },
    effective,
    allowlistedFields: Array.from(LOCAL_ROUTING_ALLOWLIST),
  };
}

function readPoolCooldownsSummary() {
  const res = readJsonSafeNoSymlink(COOLDOWNS_FILE);
  if (!res.ok) {
    return {
      ok: res.error === 'missing',
      error: res.error === 'missing' ? null : res.error,
      entries: [],
    };
  }
  const nowEpoch = Math.floor(Date.now() / 1000);
  const raw = res.data && typeof res.data === 'object' && !Array.isArray(res.data) ? res.data : {};
  const entries = Object.entries(raw).map(([key, val]) => {
    const untilEpoch = Number(val?.until_epoch || 0);
    const remainingSec = Math.max(0, untilEpoch - nowEpoch);
    return {
      key,
      pool: String(val?.pool || key.split(':')[0] || ''),
      model: String(val?.model || key.split(':').slice(1).join(':') || ''),
      reason: String(val?.reason || ''),
      untilEpoch,
      untilIso: untilEpoch > 0 ? new Date(untilEpoch * 1000).toISOString() : null,
      remainingSec,
      active: untilEpoch > nowEpoch,
    };
  });
  return { ok: true, error: null, entries };
}

function readQuotaSummary() {
  const qRes = readJsonSafeNoSymlink(GEMINI_QUOTA_FILE);
  if (!qRes.ok || !qRes.data) {
    return {
      remainingPct: null,
      reserveMode: false,
      source: 'unknown',
      updatedAt: null,
    };
  }
  return {
    remainingPct: qRes.data.meter?.five_hour_remaining_pct ?? qRes.data.gemini_remaining_pct ?? null,
    reserveMode: Boolean(qRes.data.reserve_passthrough_mode),
    source: qRes.data.source || 'auto-meter',
    updatedAt: qRes.data.updated_at || null,
  };
}

function buildBotsStatePayload() {
  readRepoHeadAndSchema();
  const config = loadOffloadBotsConfig();
  const runs = loadBotRuns();
  const activeRuns = Array.from(runningBots.values()).map((r) => ({
    botId: r.botId,
    mode: r.mode,
    startedAt: r.startedAt,
    triggeredBy: r.triggeredBy,
  }));
  const botsCatalog = Object.values(BOT_CATALOG).map((item) => ({
    ...item,
    scriptPath: `.agents/scripts/bots/${item.script}`,
  }));
  return {
    ok: true,
    environment: 'STAGING',
    botsConfigFile: BOTS_CONFIG_FILE,
    localRoutingFile: LOCAL_ROUTING_FILE,
    cooldownsFile: COOLDOWNS_FILE,
    config,
    botsCatalog,
    runningBots: activeRuns,
    recentRuns: runs,
    localRouting: readFleetAndLocalRouting(),
    poolCooldowns: readPoolCooldownsSummary(),
    quotaSummary: readQuotaSummary(),
  };
}

function validateAndMergeBotsConfig(payload, actor) {
  if (!payload || typeof payload !== 'object' || Array.isArray(payload)) {
    return { ok: false, error: 'Request body must be a JSON object.' };
  }
  const topAllowed = new Set(['bots', 'retention']);
  for (const key of Object.keys(payload)) {
    if (!topAllowed.has(key)) {
      return { ok: false, error: `Unknown configuration property "${key}".` };
    }
  }
  const current = loadOffloadBotsConfig();
  const next = JSON.parse(JSON.stringify(current));

  if (payload.retention !== undefined) {
    if (!payload.retention || typeof payload.retention !== 'object' || Array.isArray(payload.retention)) {
      return { ok: false, error: 'retention must be an object.' };
    }
    for (const k of Object.keys(payload.retention)) {
      if (k !== 'maxRunsPerBot') return { ok: false, error: `Unknown retention property "${k}".` };
    }
    if (payload.retention.maxRunsPerBot !== undefined) {
      const m = payload.retention.maxRunsPerBot;
      if (!Number.isInteger(m) || m < 5 || m > 100) {
        return { ok: false, error: 'retention.maxRunsPerBot must be an integer between 5 and 100.' };
      }
      next.retention.maxRunsPerBot = m;
    }
  }

  if (payload.bots !== undefined) {
    if (!payload.bots || typeof payload.bots !== 'object' || Array.isArray(payload.bots)) {
      return { ok: false, error: 'bots must be an object.' };
    }
    const perBotExtraKeys = {
      'ops-preflight': new Set(['includeBackendSummary', 'includeCooldowns', 'includeQuotaMeter']),
      'staging-deploy-verify': new Set(['autoVerifyHelp', 'allowedServices']),
      'release-pack-sync': new Set(['strictCleanWorktree', 'allowBundleRebuild', 'allowFleetBroadcast']),
    };
    const commonKeys = new Set(['enabled', 'schedule', 'timeoutSec', 'maxLogLines']);
    const allowedSvcSet = new Set(BOT_ALLOWED_SERVICES);

    for (const [botId, patch] of Object.entries(payload.bots)) {
      if (!Object.prototype.hasOwnProperty.call(BOT_CATALOG, botId)) {
        return { ok: false, error: `Unknown bot "${botId}".` };
      }
      if (!patch || typeof patch !== 'object' || Array.isArray(patch)) {
        return { ok: false, error: `bots.${botId} must be an object.` };
      }
      const extraSet = Object.prototype.hasOwnProperty.call(perBotExtraKeys, botId) ? perBotExtraKeys[botId] : new Set();
      for (const [k, val] of Object.entries(patch)) {
        if (!commonKeys.has(k) && !extraSet.has(k)) {
          return { ok: false, error: `Unknown property "bots.${botId}.${k}".` };
        }
        if (k === 'enabled' || k === 'includeBackendSummary' || k === 'includeCooldowns' || k === 'includeQuotaMeter' || k === 'autoVerifyHelp' || k === 'strictCleanWorktree' || k === 'allowBundleRebuild' || k === 'allowFleetBroadcast') {
          if (typeof val !== 'boolean') return { ok: false, error: `bots.${botId}.${k} must be a boolean.` };
        } else if (k === 'schedule') {
          if (typeof val !== 'string' || !VALID_BOT_SCHEDULES.has(val)) {
            return { ok: false, error: `bots.${botId}.schedule must be one of manual, hourly, daily.` };
          }
        } else if (k === 'timeoutSec') {
          if (!Number.isInteger(val) || val < 10 || val > 600) {
            return { ok: false, error: `bots.${botId}.timeoutSec must be an integer between 10 and 600.` };
          }
        } else if (k === 'maxLogLines') {
          if (!Number.isInteger(val) || val < 10 || val > 200) {
            return { ok: false, error: `bots.${botId}.maxLogLines must be an integer between 10 and 200.` };
          }
        } else if (k === 'allowedServices') {
          if (!Array.isArray(val) || val.length === 0) {
            return { ok: false, error: 'allowedServices must be a non-empty array of valid service names.' };
          }
          const clean = [];
          for (const svc of val) {
            if (typeof svc !== 'string' || !allowedSvcSet.has(svc)) {
              return { ok: false, error: `Invalid service "${svc}" in allowedServices.` };
            }
            if (!clean.includes(svc)) clean.push(svc);
          }
          next.bots[botId].allowedServices = clean;
          continue;
        }
        next.bots[botId][k] = val;
      }
    }
  }

  next.schemaVersion = hubState.schemaVersion || next.schemaVersion || '2026.11.7';
  next.environment = 'STAGING';
  next.updatedAt = new Date().toISOString();
  next.updatedBy = actor || 'admin';
  return { ok: true, config: next };
}

function executePool0Bot({ botId, mode, services = [], triggeredBy = 'admin', callerToken = '' }) {
  if (!Object.prototype.hasOwnProperty.call(BOT_CATALOG, botId)) {
    return Promise.resolve({ ok: false, status: 400, error: `Unknown botId "${botId}"` });
  }
  const spec = BOT_CATALOG[botId];
  const effectiveMode = mode || spec.defaultMode;
  if (!spec.modes.includes(effectiveMode)) {
    return Promise.resolve({ ok: false, status: 400, error: `Invalid mode "${effectiveMode}" for bot "${botId}"` });
  }
  const config = loadOffloadBotsConfig();
  const botCfg = config.bots[botId];
  if (!botCfg || botCfg.enabled !== true) {
    return Promise.resolve({ ok: false, status: 409, error: `Bot "${botId}" is disabled in offload-bots.json.` });
  }
  if (runningBots.has(botId)) {
    return Promise.resolve({ ok: false, status: 409, error: `Bot "${botId}" is already running.` });
  }

  let validatedServices = [];
  if (botId === 'staging-deploy-verify' && effectiveMode === 'deploy') {
    if (!Array.isArray(services) || services.length === 0) {
      return Promise.resolve({ ok: false, status: 400, error: 'deploy mode requires a non-empty services array.' });
    }
    const allowedSet = new Set(
      (Array.isArray(botCfg.allowedServices) ? botCfg.allowedServices : []).filter((s) => BOT_ALLOWED_SERVICES.includes(s))
    );
    for (const rawSvc of services) {
      const svc = typeof rawSvc === 'string' ? rawSvc.trim() : '';
      if (!/^[a-z0-9-]+$/.test(svc) || !BOT_ALLOWED_SERVICES.includes(svc) || !allowedSet.has(svc)) {
        return Promise.resolve({ ok: false, status: 400, error: `Disallowed deploy service "${svc}".` });
      }
      if (!validatedServices.includes(svc)) validatedServices.push(svc);
    }
  } else if (Array.isArray(services) && services.length > 0) {
    return Promise.resolve({ ok: false, status: 400, error: 'services parameter is only valid for staging-deploy-verify deploy mode.' });
  }

  const botsDir = path.resolve(WORKSPACE_DIR, '.agents', 'scripts', 'bots');
  const scriptPath = path.resolve(botsDir, spec.script);
  if (!scriptPath.startsWith(botsDir + path.sep) || !fs.existsSync(scriptPath)) {
    return Promise.resolve({ ok: false, status: 500, error: `Bot script missing: ${spec.script}` });
  }

  const argv = [scriptPath, '--mode', effectiveMode];
  if (validatedServices.length > 0) {
    argv.push('--services', validatedServices.join(','));
  }

  const startedAt = new Date().toISOString();
  const startMs = Date.now();
  const runId = `${botId}-${Date.now()}-${crypto.randomBytes(3).toString('hex')}`;
  runningBots.set(botId, { botId, mode: effectiveMode, startedAt, triggeredBy });

  const childEnv = {
    ...process.env,
    AGY_WORKSPACE_DIR: WORKSPACE_DIR,
    AGY_ORCHESTRATOR_REPO_DIR: hubConfig.repoDir,
    AGY_BOTS_CONFIG_FILE: BOTS_CONFIG_FILE,
    AGY_LOCAL_ROUTING_FILE: LOCAL_ROUTING_FILE,
    AGY_COOLDOWNS_FILE: COOLDOWNS_FILE,
    AGY_GEMINI_QUOTA_FILE: GEMINI_QUOTA_FILE,
  };
  delete childEnv.AGY_BOT_CALLER_JWT;
  if (botId === 'ops-preflight' && callerToken) {
    childEnv.AGY_BOT_CALLER_JWT = callerToken;
  }

  const baseTimeoutSec = Math.min(600, Math.max(10, Number(botCfg.timeoutSec) || 60));
  const outerGraceMs = botId === 'staging-deploy-verify' && effectiveMode === 'deploy' ? 20000 : 5000;
  const timeoutMs = baseTimeoutSec * 1000 + outerGraceMs;

  return new Promise((resolve) => {
    execFile(
      process.execPath,
      argv,
      {
        cwd: WORKSPACE_DIR,
        timeout: timeoutMs,
        shell: false,
        env: childEnv,
        maxBuffer: 4 * 1024 * 1024,
      },
      (err, stdout, stderr) => {
        runningBots.delete(botId);
        const finishedAt = new Date().toISOString();
        const durationMs = Date.now() - startMs;
        const cleanStdout = scrubSensitiveOutput(stdout).slice(0, 8192);
        const cleanStderr = scrubSensitiveOutput(stderr).slice(0, 4096);

        let parsed = null;
        try {
          parsed = JSON.parse(String(stdout || '').trim());
        } catch {}

        const runRecord = {
          runId,
          botId,
          mode: effectiveMode,
          services: validatedServices,
          triggeredBy,
          startedAt,
          finishedAt,
          durationMs,
          ok: Boolean(parsed ? parsed.ok : !err),
          exitCode: err ? (typeof err.code === 'number' ? err.code : 1) : 0,
          summary: parsed?.summary ? scrubSensitiveOutput(parsed.summary) : err ? `Exited with error (${runRecordFallbackMsg(err)})` : 'Completed',
          checks: Array.isArray(parsed?.checks)
            ? parsed.checks.map((c) => ({
                id: String(c.id || ''),
                status: String(c.status || 'INFO'),
                detail: scrubSensitiveOutput(c.detail || ''),
              }))
            : [],
          metrics: parsed?.metrics && typeof parsed.metrics === 'object' ? parsed.metrics : {},
          estimatedTokensSaved: Number(parsed?.estimatedTokensSaved ?? spec.estimatedTokensSaved ?? 0),
          rawTail: cleanStderr ? `${cleanStdout}\n[stderr]\n${cleanStderr}`.slice(-8192) : cleanStdout,
        };

        try {
          appendBotRunRecord(runRecord, config.retention?.maxRunsPerBot || 25);
        } catch {}

        resolve({ ok: true, status: 200, run: runRecord });
      }
    );
  });
}

function runRecordFallbackMsg(err) {
  return scrubSensitiveOutput(err?.message || 'failed').slice(0, 160);
}

function readRequestBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let total = 0;
    req.on('data', (chunk) => {
      total += chunk.length;
      if (total > MAX_BODY_BYTES) {
        reject(new Error('Payload too large'));
        req.destroy();
        return;
      }
      chunks.push(chunk);
    });
    req.on('end', () => resolve(Buffer.concat(chunks)));
    req.on('error', reject);
  });
}

function sendJson(res, status, payload, extraHeaders = {}) {
  res.writeHead(status, {
    'Content-Type': 'application/json; charset=utf-8',
    'Cache-Control': 'no-store',
    ...extraHeaders,
  });
  res.end(JSON.stringify(payload, null, 2));
}

function sendText(res, status, text, contentType = 'text/plain; charset=utf-8', filename = null) {
  const headers = {
    'Content-Type': contentType,
    'Cache-Control': 'no-store',
  };
  if (filename) {
    headers['Content-Disposition'] = `attachment; filename="${filename}"`;
  }
  res.writeHead(status, headers);
  res.end(text);
}

function writeSseEvent(res, eventName, data) {
  try {
    res.write(`event: ${eventName}\ndata: ${JSON.stringify(data)}\n\n`);
  } catch {}
}

function broadcastSyncEvent(reason = 'publish') {
  const info = readRepoHeadAndSchema();
  const payload = {
    commit: info.commit,
    schemaVersion: info.schemaVersion,
    updatedAt: info.updatedAt,
    pushedAt: new Date().toISOString(),
    reason,
  };
  hubState.lastPushAt = payload.pushedAt;

  let broadcastedCount = 0;
  for (const client of sseClients.values()) {
    writeSseEvent(client.res, 'sync', payload);
    broadcastedCount += 1;
  }
  return { ...payload, broadcastedCount };
}

function resolveAckWaiters(commit, nodeId) {
  const set = pendingAckWaiters.get(commit);
  if (!set) return;
  for (const waiter of set) {
    waiter.ackedNodes.add(nodeId);
    if (waiter.expectedCount > 0 && waiter.ackedNodes.size >= waiter.expectedCount) {
      clearTimeout(waiter.timer);
      set.delete(waiter);
      waiter.resolve(Array.from(waiter.ackedNodes));
    }
  }
  if (set.size === 0) pendingAckWaiters.delete(commit);
}

function waitForAcks(commit, expectedCount, timeoutMs = 3500) {
  if (!commit || expectedCount <= 0) return Promise.resolve([]);
  return new Promise((resolve) => {
    let set = pendingAckWaiters.get(commit);
    if (!set) {
      set = new Set();
      pendingAckWaiters.set(commit, set);
    }
    const waiter = {
      expectedCount,
      ackedNodes: new Set(),
      resolve: (acks) => resolve(acks),
      timer: null,
    };
    waiter.timer = setTimeout(() => {
      set.delete(waiter);
      if (set.size === 0) pendingAckWaiters.delete(commit);
      resolve(Array.from(waiter.ackedNodes));
    }, timeoutMs);
    set.add(waiter);
  });
}

function buildConfigTemplates() {
  const turboConfigJson = JSON.stringify(
    {
      userSettings: {
        nonWorkspaceFileAccessPolicy: 'AGENT_SETTING_POLICY_ALLOW',
        allowCascadeAccessGitignoreFiles: true,
        autoExecutionPolicy: 'CASCADE_COMMANDS_AUTO_EXECUTION_EAGER',
        permissionPreset: 'AGENT_PERMISSION_PRESET_TURBO',
        enableTerminalSandbox: false,
      },
    },
    null,
    2
  );

  const fleetSyncNickLaptop = JSON.stringify(
    {
      hubUrl: hubConfig.publicHubUrl,
      fleetToken: hubConfig.fleetToken,
      nodeId: 'nick-laptop',
      label: 'Nick Laptop (Windows 11)',
      location: 'Κοπανός / Mobile (Personal)',
      os: 'Windows 11',
      expectedProfile: 'nick-laptop',
      dailyFallbackSeconds: 86400,
    },
    null,
    2
  );

  const fleetSyncWin11 = JSON.stringify(
    {
      hubUrl: hubConfig.publicHubUrl,
      fleetToken: hubConfig.fleetToken,
      nodeId: 'oraiokastro-win11',
      label: 'Soti-Laptop (Windows 11 Pro)',
      location: 'Ωραιόκαστρο',
      os: 'Windows 11 Pro',
      expectedProfile: 'oraiokastro-win11',
      dailyFallbackSeconds: 86400,
    },
    null,
    2
  );

  const fleetSyncOmarchy = JSON.stringify(
    {
      hubUrl: hubConfig.publicHubUrl,
      fleetToken: hubConfig.fleetToken,
      nodeId: 'kopanos-omarchy',
      label: 'Omarchy Workstation',
      location: 'Κοπανός Ημαθίας',
      os: 'Omarchy Linux (Arch / Hyprland)',
      expectedProfile: 'kopanos-omarchy',
      dailyFallbackSeconds: 86400,
    },
    null,
    2
  );

  const mcpConfigWin11 = JSON.stringify(
    {
      mcpServers: {
        'agy-fleet': {
          command: 'node',
          args: ['%USERPROFILE%\\.local\\lib\\agy-fleet\\agy-fleet-mcp.js'],
        },
      },
    },
    null,
    2
  );

  const mcpConfigOmarchy = JSON.stringify(
    {
      mcpServers: {
        'agy-fleet': {
          command: 'node',
          args: ['$HOME/.local/lib/agy-fleet/agy-fleet-mcp.js'],
        },
      },
    },
    null,
    2
  );

  let windowsSilentVbs = '';
  try {
    windowsSilentVbs = fs.readFileSync(path.join(hubConfig.repoDir, 'fleet', 'agy-silent-launch.vbs'), 'utf8');
  } catch {
    windowsSilentVbs = 'Set WshShell = CreateObject("WScript.Shell")\nIf WScript.Arguments.Count > 0 Then\n  WshShell.Run WScript.Arguments(0), 0, False\nEnd If\n';
  }

  const systemdDaemonUnit = `[Unit]
Description=Antigravity Real-Time SSE Fleet Push Daemon
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment=HOME=%h
Environment=PATH=%h/.local/share/mise/shims:%h/.local/bin:%h/.opencode/bin:%h/.npm-global/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ExecStart=/usr/bin/env node %h/.local/lib/agy-fleet/agy-sync-daemon.js
Restart=always
RestartSec=3

[Install]
WantedBy=default.target
`;

  const systemdTimerUnit = `[Unit]
Description=Run Antigravity Orchestrator Architecture Sync once daily (safety net)

[Timer]
OnCalendar=daily
Persistent=true
RandomizedDelaySec=120
Unit=agy-orchestrator-sync.service

[Install]
WantedBy=timers.target
`;

  let modelRoutingPreview = '';
  try {
    modelRoutingPreview = fs.readFileSync(
      path.join(hubConfig.repoDir, 'global', 'gemini', 'config', 'model-routing.json'),
      'utf8'
    );
  } catch {}

  const bootstrapUrlNickLaptop = `${hubConfig.publicHubUrl}/bootstrap.ps1?token=${hubConfig.fleetToken}&profile=nick-laptop`;
  const bootstrapUrlWin11 = `${hubConfig.publicHubUrl}/bootstrap.ps1?token=${hubConfig.fleetToken}&profile=oraiokastro-win11`;
  const bootstrapUrlOmarchy = `${hubConfig.publicHubUrl}/bootstrap.sh?token=${hubConfig.fleetToken}&profile=kopanos-omarchy`;
  const elevatedGatekeeperCommand = `if (([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { & "$env:USERPROFILE\\Development\\antigravity-orchestrator\\install.ps1" -SkipClis } else { Start-Process powershell.exe -Verb RunAs -Wait -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File \`"$env:USERPROFILE\\Development\\antigravity-orchestrator\\install.ps1\`" -SkipClis" }`;

  return {
    hub: {
      status: 'UP',
      latestCommit: hubState.latestCommit,
      schemaVersion: hubState.schemaVersion,
      lastPushAt: hubState.lastPushAt,
      lastWebhookAt: hubState.lastWebhookAt,
      webhookConfigured: Boolean(hubConfig.webhookSecret),
      connectedCount: sseClients.size,
      totalNodes: Object.keys(nodesState).length,
      syncMode: 'sse-push+daily-fallback',
      dailyFallbackSeconds: 86400,
      publicHubUrl: hubConfig.publicHubUrl,
      repoUrl: hubConfig.repoUrl,
      uptimeSeconds: Math.floor((Date.now() - STARTED_AT) / 1000),
    },
    fleetToken: hubConfig.fleetToken,
    nodes: getOrderedNodes(),
    profiles: {
      'nick-laptop': {
        nodeId: 'nick-laptop',
        label: 'Nick Laptop — Windows 11 (Personal)',
        location: 'Κοπανός / Mobile (Personal)',
        os: 'Windows 11',
        bootstrapUrl: bootstrapUrlNickLaptop,
        bootstrapCommand: `[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; irm "${bootstrapUrlNickLaptop}" | iex`,
        elevatedGatekeeperCommand,
        cliAuthCommand: `codex login; claude login`,
        smokeTestCommand: `agy-init-workspace.ps1 -WorkspacePath "C:\\Users\\parda\\OneDrive\\Dev\\ha"\nInvoke-RestMethod http://127.0.0.1:18099/api/gatekeeper/health`,
        fleetSyncJson: fleetSyncNickLaptop,
        mcpConfigJson: mcpConfigWin11,
        turboConfigJson,
        daemonConfig: windowsSilentVbs,
      },
      'oraiokastro-win11': {
        nodeId: 'oraiokastro-win11',
        label: 'Soti-Laptop — Windows 11 Pro (Ωραιόκαστρο)',
        location: 'Ωραιόκαστρο',
        os: 'Windows 11 Pro',
        bootstrapUrl: bootstrapUrlWin11,
        bootstrapCommand: `[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; irm "${bootstrapUrlWin11}" | iex`,
        elevatedGatekeeperCommand,
        cliAuthCommand: `codex login; claude login`,
        smokeTestCommand: `agy-init-workspace.ps1 -WorkspacePath "C:\\Users\\soti\\Development\\my-project"\nInvoke-RestMethod http://127.0.0.1:18099/api/gatekeeper/health`,
        fleetSyncJson: fleetSyncWin11,
        mcpConfigJson: mcpConfigWin11,
        turboConfigJson,
        daemonConfig: windowsSilentVbs,
      },
      'kopanos-omarchy': {
        nodeId: 'kopanos-omarchy',
        label: 'Omarchy Linux — Κοπανός Ημαθίας',
        location: 'Κοπανός Ημαθίας',
        os: 'Omarchy Linux (Arch / Hyprland)',
        bootstrapUrl: bootstrapUrlOmarchy,
        bootstrapCommand: `curl -fsSL "${bootstrapUrlOmarchy}" | bash`,
        cliAuthCommand: `agy-setup-clis --auth && agy-setup-clis --test`,
        smokeTestCommand: `systemctl --user status agy-sync-daemon.service agy-orchestrator-sync.timer --no-pager\ncurl -fsS http://127.0.0.1:18099/api/gatekeeper/health`,
        fleetSyncJson: fleetSyncOmarchy,
        mcpConfigJson: mcpConfigOmarchy,
        turboConfigJson,
        daemonConfig: `# ~/.config/systemd/user/agy-sync-daemon.service\n${systemdDaemonUnit}\n# ~/.config/systemd/user/agy-orchestrator-sync.timer\n${systemdTimerUnit}`,
      },
    },
    modelRoutingPreview,
  };
}

function renderBootstrapPs1(profileId) {
  const profile = CANONICAL_PROFILES[profileId] || CANONICAL_PROFILES['nick-laptop'];
  const hubUrl = hubConfig.publicHubUrl;
  const token = hubConfig.fleetToken;
  const repoUrl = hubConfig.repoUrl;

  return `# =============================================================================
# Antigravity Workstation Bootstrap — ${profile.label}
# Location: ${profile.location} | Mode: Real-Time SSE Push + 1x Daily Fallback
# =============================================================================
# PowerShell 5.1 safe: keep Continue globally so git/npm stderr never aborts setup.
$ErrorActionPreference = "Continue"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$userHome = $HOME
if (-not $userHome) { $userHome = $env:USERPROFILE }

function Write-Utf8NoBom {
    param([string]$Path, [string]$Content)
    $parent = Split-Path -Parent $Path
    if ($parent -and -not (Test-Path $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $enc)
}

function Strip-Utf8BomFile {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return }
    try {
        $bytes = [System.IO.File]::ReadAllBytes($Path)
        if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
            $clean = [System.Text.Encoding]::UTF8.GetString($bytes, 3, $bytes.Length - 3)
            Write-Utf8NoBom -Path $Path -Content $clean
        }
    } catch {}
}

function Invoke-GitCmd {
    param([string[]]$GitArgs)
    $prevPref = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $cmdOut = & git @GitArgs 2>&1
    $exitCode = $LASTEXITCODE
    $ErrorActionPreference = $prevPref
    return [pscustomobject]@{
        ExitCode = $exitCode
        Output   = ($cmdOut | Out-String).Trim()
    }
}

Write-Host "🚀 Antigravity Workstation Setup: ${profile.label} (${profile.location})" -ForegroundColor Cyan

# Ensure common toolchain directories are visible in current session PATH
foreach ($p in @(
    (Join-Path $env:ProgramFiles "nodejs"),
    (Join-Path $env:ProgramFiles "Git\\cmd"),
    (Join-Path $env:LOCALAPPDATA "Programs\\nodejs"),
    (Join-Path $userHome ".local\\bin")
)) {
    if ((Test-Path $p) -and ($env:Path -notlike "*$p*")) {
        $env:Path = "$p;$env:Path"
    }
}

# 0. Corrective Cleanup: Undo wrong-profile install (e.g. accidental Soti-Laptop run) & stop stale daemons/BOMs
$geminiConfigDir = Join-Path $userHome ".gemini\\config"
New-Item -ItemType Directory -Path $geminiConfigDir -Force | Out-Null
$fleetSyncPath = Join-Path $geminiConfigDir "fleet-sync.json"
$daemonPidFile = Join-Path $geminiConfigDir ".agy-sync-daemon.pid"
$migratedFromNodeId = ""

if (Test-Path $fleetSyncPath) {
    try {
        $oldRaw = ([System.IO.File]::ReadAllText($fleetSyncPath, [System.Text.Encoding]::UTF8)).TrimStart([char]0xFEFF)
        $oldCfg = $oldRaw | ConvertFrom-Json
        if ($oldCfg -and $oldCfg.nodeId -and ($oldCfg.nodeId -ne "${profile.nodeId}")) {
            $migratedFromNodeId = [string]$oldCfg.nodeId
            Write-Host ""
            Write-Host "🧹 Corrective Action: Detected '$migratedFromNodeId' profile on this laptop — migrating cleanly to '${profile.nodeId}' (${profile.label})..." -ForegroundColor Yellow
        }
    } catch {}
}

# Always stop any pre-existing agy-sync-daemon.js process before rewriting config & restarting
if (Test-Path $daemonPidFile) {
    try {
        $oldPid = [int](([System.IO.File]::ReadAllText($daemonPidFile, [System.Text.Encoding]::UTF8)).TrimStart([char]0xFEFF).Trim())
        if ($oldPid -gt 0) {
            Stop-Process -Id $oldPid -Force -ErrorAction SilentlyContinue
        }
    } catch {}
    Remove-Item -Path $daemonPidFile -Force -ErrorAction SilentlyContinue
}
try {
    Get-CimInstance Win32_Process -Filter "Name = 'node.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like "*agy-sync-daemon.js*" } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
} catch {}

# Clean legacy task names cleanly if owned by current user
foreach ($legacyTask in @("AgyOrchestratorAutoSync", "AntigravityArchSync", "ArchitectureSync")) {
    try {
        if (Get-ScheduledTask -TaskName $legacyTask -ErrorAction SilentlyContinue) {
            Stop-ScheduledTask -TaskName $legacyTask -ErrorAction SilentlyContinue
            Unregister-ScheduledTask -TaskName $legacyTask -Confirm:$false -ErrorAction SilentlyContinue
            Write-Host "   ✓ Unregistered legacy task: $legacyTask" -ForegroundColor Green
        }
    } catch {}
}

# Strip any accidental PS 5.1 UTF-8 BOM from existing JSON config files
Strip-Utf8BomFile -Path (Join-Path $geminiConfigDir "mcp_config.json")
Strip-Utf8BomFile -Path (Join-Path $geminiConfigDir "config.json")
Strip-Utf8BomFile -Path (Join-Path $geminiConfigDir "orchestrator-workspaces.json")
if ($env:APPDATA) {
    Strip-Utf8BomFile -Path (Join-Path $env:APPDATA "Antigravity\\User\\settings.json")
}

# Tell Fleet Hub to reset mistaken profile slot back to PENDING_INSTALL if we migrated profiles
if ($migratedFromNodeId) {
    try {
        $releaseBody = @{
            previousNodeId = $migratedFromNodeId
            newNodeId      = "${profile.nodeId}"
            hostname       = $env:COMPUTERNAME
        } | ConvertTo-Json -Compress
        Invoke-RestMethod -Method Post -Uri "${hubUrl}/release-node" -Headers @{ Authorization = "Bearer ${token}" } -ContentType "application/json" -Body $releaseBody -TimeoutSec 5 -ErrorAction SilentlyContinue | Out-Null
        Write-Host "   ✓ Released previous profile slot '$migratedFromNodeId' on DevBox Fleet Hub" -ForegroundColor Green
    } catch {}
}

# 1. Check / Install Git & Node.js LTS
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Host "⬇️ Installing Git via winget..." -ForegroundColor Yellow
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        winget install --id Git.Git -e --source winget --accept-package-agreements --accept-source-agreements
        $env:Path = "$(Join-Path $env:ProgramFiles 'Git\\cmd');$env:Path"
    } else {
        throw "Git is not installed and winget is unavailable. Install Git for Windows first."
    }
}

if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
    Write-Host "⬇️ Installing Node.js LTS via winget..." -ForegroundColor Yellow
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        winget install --id OpenJS.NodeJS.LTS -e --source winget --accept-package-agreements --accept-source-agreements
        $env:Path = "$(Join-Path $env:ProgramFiles 'nodejs');$env:Path"
    } else {
        throw "Node.js is not installed and winget is unavailable. Install Node.js LTS first."
    }
}

# 2. Clone or update antigravity-orchestrator (PS 5.1 stderr-safe)
$devDir = Join-Path $userHome "Development"
$repoDir = Join-Path $devDir "antigravity-orchestrator"
New-Item -ItemType Directory -Path $devDir -Force | Out-Null

if (-not (Test-Path (Join-Path $repoDir ".git"))) {
    Write-Host "📦 Cloning ${repoUrl} -> $repoDir..." -ForegroundColor Cyan
    $cloneRes = Invoke-GitCmd @("clone", "${repoUrl}", "$repoDir")
    if ($cloneRes.ExitCode -ne 0) {
        throw "git clone failed: $($cloneRes.Output)"
    }
} else {
    Write-Host "🔄 Updating $repoDir from origin/main..." -ForegroundColor Cyan
    $originRes = Invoke-GitCmd @("-C", "$repoDir", "remote", "get-url", "origin")
    if ($originRes.ExitCode -eq 0 -and $originRes.Output -like "git@*") {
        Invoke-GitCmd @("-C", "$repoDir", "remote", "set-url", "origin", "${repoUrl}") | Out-Null
    }
    Invoke-GitCmd @("-C", "$repoDir", "stash", "push", "-u", "-m", "pre-fleet-bootstrap-backup") | Out-Null
    $fetchRes = Invoke-GitCmd @("-C", "$repoDir", "fetch", "origin", "main")
    if ($fetchRes.ExitCode -ne 0) {
        throw "git fetch origin main failed: $($fetchRes.Output)"
    }
    $coRes = Invoke-GitCmd @("-C", "$repoDir", "checkout", "-B", "main", "origin/main")
    if ($coRes.ExitCode -ne 0) {
        throw "git checkout -B main failed: $($coRes.Output)"
    }
    $resetRes = Invoke-GitCmd @("-C", "$repoDir", "reset", "--hard", "origin/main")
    if ($resetRes.ExitCode -ne 0) {
        throw "git reset --hard origin/main failed: $($resetRes.Output)"
    }
    Write-Host "   ✓ Repository synchronized to latest origin/main" -ForegroundColor Green
}

# 3. Write BOM-free fleet-sync.json BEFORE running install.ps1
$fleetCfg = [ordered]@{
    hubUrl               = "${hubUrl}"
    fleetToken           = "${token}"
    nodeId               = "${profile.nodeId}"
    label                = "${profile.label}"
    location             = "${profile.location}"
    os                   = "${profile.os}"
    expectedProfile      = "${profile.expectedProfile}"
    dailyFallbackSeconds = 86400
}
$fleetJson = ($fleetCfg | ConvertTo-Json -Depth 5) + "\`n"
Write-Utf8NoBom -Path $fleetSyncPath -Content $fleetJson
Write-Host "   ✓ Saved BOM-free $fleetSyncPath (nodeId=${profile.nodeId})" -ForegroundColor Green

# 4. Run repository installer (sets rules, Turbo CitC, MCP config, Gatekeeper, Silent Daemon & 1x Daily task)
& (Join-Path $repoDir "install.ps1")

# Re-assert BOM-free fleet-sync.json for target profile
Write-Utf8NoBom -Path $fleetSyncPath -Content $fleetJson

# 4a. Sync any existing .agents workspaces under $HOME\\Development and $HOME\\OneDrive\\Dev safely
$initWsScript = Join-Path $repoDir "bin\\agy-init-workspace.ps1"
if (Test-Path $initWsScript) {
    foreach ($parentDir in @(
        (Join-Path $userHome "Development"),
        (Join-Path $userHome "OneDrive\\Dev")
    )) {
        if (Test-Path $parentDir) {
            Get-ChildItem -Path $parentDir -Directory -ErrorAction SilentlyContinue | ForEach-Object {
                if (($_.Name -ne "antigravity-orchestrator") -and (Test-Path (Join-Path $_.FullName ".agents"))) {
                    Write-Host "   🔄 Refreshing existing workspace: $($_.FullName)" -ForegroundColor DarkGray
                    try { & $initWsScript -WorkspacePath $_.FullName } catch {}
                }
            }
        }
    }
}

# 4b. Verify legacy 30m / alternate tasks are gone; elevate once if Admin-owned task resisted non-elevated overwrite
$needsElevation = $false
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
try {
    $autoTask = Get-ScheduledTask -TaskName "AntigravityOrchestratorAutoSync" -ErrorAction SilentlyContinue
    if ($autoTask -and $autoTask.Triggers -and $autoTask.Triggers[0].Repetition -and $autoTask.Triggers[0].Repetition.Interval) {
        $needsElevation = $true
    }
    foreach ($legacyName in @("AgyOrchestratorAutoSync", "AntigravityArchSync", "ArchitectureSync")) {
        if (Get-ScheduledTask -TaskName $legacyName -ErrorAction SilentlyContinue) {
            $needsElevation = $true
        }
    }
} catch {}

if (-not $isAdmin -and $needsElevation) {
    Write-Host "🔐 Legacy 30-minute Scheduled Task requires Administrator privileges to replace cleanly — requesting UAC elevation..." -ForegroundColor Yellow
    try {
        Start-Process powershell.exe -Verb RunAs -Wait -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File \`"$repoDir\\install.ps1\`" -SkipClis"
    } catch {
        Write-Host "   ⚠️ Elevation declined. Run once as Administrator: & '$repoDir\\install.ps1' -SkipClis" -ForegroundColor Yellow
    }
} elseif (-not $isAdmin) {
    Write-Host ""
    Write-Host "ℹ️  To enable full Layer 1 NT AUTHORITY\\SYSTEM Gatekeeper TCB lock, run once in Administrator PowerShell:" -ForegroundColor Yellow
    Write-Host "   & '$repoDir\\install.ps1' -SkipClis" -ForegroundColor White
}

# 5. Send immediate ACK to Staging Fleet Hub so workstation flips to ONLINE + IN_SYNC right away
$daemonJs = Join-Path $userHome ".local\\lib\\agy-fleet\\agy-sync-daemon.js"
if ((Get-Command node -ErrorAction SilentlyContinue) -and (Test-Path $daemonJs)) {
    try {
        & node "$daemonJs" --once
    } catch {}
}

Write-Host "✅ ${profile.label} cleaned up, configured (UTF-8 no-BOM), and connected to Real-Time SSE Push Hub!" -ForegroundColor Green
`;
}

function renderBootstrapSh(profileId) {
  const profile = CANONICAL_PROFILES[profileId] || CANONICAL_PROFILES['kopanos-omarchy'];
  const hubUrl = hubConfig.publicHubUrl;
  const token = hubConfig.fleetToken;
  const repoUrl = hubConfig.repoUrl;

  return `#!/usr/bin/env bash
# =============================================================================
# Antigravity Workstation Bootstrap — ${profile.label}
# Location: ${profile.location} | Mode: Real-Time SSE Push + 1x Daily Fallback
# =============================================================================
set -euo pipefail

export HOME="\${HOME:-\$(getent passwd "\$(id -un)" 2>/dev/null | cut -d: -f6 || echo "/home/\$(id -un)")}"
export PATH="\${HOME}/.local/share/mise/shims:\${HOME}/.local/bin:\${HOME}/.opencode/bin:\${HOME}/.npm-global/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:\${PATH:-}"

echo "🚀 Antigravity Workstation Setup: ${profile.label} (${profile.location})"

# 1. Detect Omarchy / Arch Linux or Debian/Ubuntu and ensure prerequisites
MISSING=()
for cmd in git curl jq node npm; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    MISSING+=("$cmd")
  fi
done

if [ "\${#MISSING[@]}" -gt 0 ]; then
  echo "⚙️ Missing tools detected: \${MISSING[*]}"
  if [ -f /etc/arch-release ] || command -v pacman >/dev/null 2>&1; then
    echo "   🐧 Detected Arch / Omarchy Linux — installing prerequisites via pacman..."
    ARCH_PKGS=()
    for cmd in "\${MISSING[@]}"; do
      case "$cmd" in
        node) ARCH_PKGS+=("nodejs") ;;
        *) ARCH_PKGS+=("$cmd") ;;
      esac
    done
    sudo pacman -S --needed --noconfirm "\${ARCH_PKGS[@]}"
  elif command -v apt-get >/dev/null 2>&1; then
    sudo apt-get update && sudo apt-get install -y jq curl git nodejs npm
  elif command -v brew >/dev/null 2>&1; then
    brew install jq git node
  fi
fi

# Refresh PATH in case mise/node was already present or newly installed
export PATH="\${HOME}/.local/share/mise/shims:\${HOME}/.local/bin:\${HOME}/.opencode/bin:\${HOME}/.npm-global/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:\${PATH:-}"

# 2. Clone or clean-update antigravity-orchestrator (stashing any old local edits first)
DEV_DIR="\${HOME}/Development"
REPO_DIR="\${DEV_DIR}/antigravity-orchestrator"
mkdir -p "\$DEV_DIR"

if [ ! -d "\${REPO_DIR}/.git" ]; then
  echo "📦 Cloning ${repoUrl} -> \${REPO_DIR}..."
  git clone "${repoUrl}" "\$REPO_DIR"
else
  echo "🔄 Updating \${REPO_DIR} from origin/main..."
  git -C "\$REPO_DIR" stash push -u -m "pre-fleet-bootstrap-backup" >/dev/null 2>&1 || true
  git -C "\$REPO_DIR" fetch origin main
  git -C "\$REPO_DIR" checkout -B main origin/main
  git -C "\$REPO_DIR" reset --hard origin/main
fi

# 3. Write ~/.gemini/config/fleet-sync.json (mode 0600) & remediate previous profile if switched
CONFIG_DIR="\${HOME}/.gemini/config"
mkdir -p "\$CONFIG_DIR"
PREV_NODE_ID=""
if [ -f "\${CONFIG_DIR}/fleet-sync.json" ]; then
  PREV_NODE_ID=$(jq -r '.nodeId // empty' "\${CONFIG_DIR}/fleet-sync.json" 2>/dev/null || echo "")
fi
if [ -n "\$PREV_NODE_ID" ] && [ "\$PREV_NODE_ID" != "${profile.nodeId}" ]; then
  echo "🧹 Corrective Action: Migrating profile from '\${PREV_NODE_ID}' to '${profile.nodeId}'..."
  if command -v systemctl >/dev/null 2>&1; then
    systemctl --user stop agy-sync-daemon.service 2>/dev/null || true
  fi
  rm -f "\${CONFIG_DIR}/.agy-sync-daemon.pid"
  curl -fsSL -X POST "${hubUrl}/release-node" \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    -d "{\\"previousNodeId\\":\\"\${PREV_NODE_ID}\\",\\"newNodeId\\":\\"${profile.nodeId}\\",\\"hostname\\":\\"\$(hostname)\\"}" >/dev/null 2>&1 || true
fi
umask 077
cat > "\${CONFIG_DIR}/fleet-sync.json" <<'EOF'
{
  "hubUrl": "${hubUrl}",
  "fleetToken": "${token}",
  "nodeId": "${profile.nodeId}",
  "label": "${profile.label}",
  "location": "${profile.location}",
  "os": "${profile.os}",
  "expectedProfile": "${profile.expectedProfile}",
  "dailyFallbackSeconds": 86400
}
EOF
chmod 600 "\${CONFIG_DIR}/fleet-sync.json"
echo "   ✓ Saved \${CONFIG_DIR}/fleet-sync.json (0600)"

# 4. Run full installer with Gatekeeper service
bash "\${REPO_DIR}/install.sh" --with-gatekeeper

# 5. Verify live SSE connection and report initial ACK to Staging Hub
if command -v systemctl >/dev/null 2>&1; then
  systemctl --user restart agy-sync-daemon.service 2>/dev/null || true
fi
if [ -f "\${HOME}/.local/lib/agy-fleet/agy-sync-daemon.js" ] && command -v node >/dev/null 2>&1; then
  node "\${HOME}/.local/lib/agy-fleet/agy-sync-daemon.js" --once || true
fi

echo "✅ ${profile.label} synced and connected to Real-Time SSE Push Hub + 1x Daily fallback!"
`;
}

function handleWebhookPush(req, rawBody, res) {
  const sig = req.headers['x-hub-signature-256'] || '';
  if (!sig || typeof sig !== 'string' || !sig.startsWith('sha256=')) {
    return sendJson(res, 401, { ok: false, error: 'Missing X-Hub-Signature-256' });
  }
  const expected = 'sha256=' + crypto.createHmac('sha256', hubConfig.webhookSecret).update(rawBody).digest('hex');
  if (!constantTimeTokenEqual(sig, expected)) {
    return sendJson(res, 401, { ok: false, error: 'Invalid webhook signature' });
  }

  const ghEvent = String(req.headers['x-github-event'] || '');
  hubState.lastWebhookAt = new Date().toISOString();
  hubState.lastWebhookEvent = ghEvent;

  if (ghEvent === 'ping') {
    return sendJson(res, 200, { ok: true, pong: true });
  }

  let payload = {};
  try {
    payload = JSON.parse(rawBody.toString('utf8') || '{}');
  } catch {}

  if (ghEvent === 'push' && payload.ref && payload.ref !== 'refs/heads/main') {
    return sendJson(res, 200, { ok: true, ignoredRef: payload.ref });
  }

  // Pull fast-forward safely in repoDir before broadcasting
  execFile('git', ['-C', hubConfig.repoDir, 'fetch', 'origin', 'main'], { timeout: 15000 }, () => {
    execFile('git', ['-C', hubConfig.repoDir, 'merge', '--ff-only', 'origin/main'], { timeout: 10000 }, () => {
      const result = broadcastSyncEvent(`github-webhook:${ghEvent || 'push'}`);
      sendJson(res, 200, { ok: true, ...result });
    });
  });
}

function updateDevBoxLocalFleetToken(newToken) {
  const localFleetPath = path.join(USER_HOME, '.gemini', 'config', 'fleet-sync.json');
  if (!fs.existsSync(localFleetPath)) return;
  try {
    const parsed = JSON.parse(fs.readFileSync(localFleetPath, 'utf8'));
    parsed.fleetToken = newToken;
    writePrivateJson(localFleetPath, parsed);
    execFile('systemctl', ['--user', 'restart', 'agy-sync-daemon.service'], { timeout: 5000 }, () => {});
  } catch {}
}

const server = http.createServer(async (req, res) => {
  try {
    const urlObj = new URL(req.url, `http://127.0.0.1:${PORT}`);
    const p = urlObj.pathname;

    // 1. Public Health
    if (req.method === 'GET' && p === '/api/agy-fleet/health') {
      readRepoHeadAndSchema();
      return sendJson(res, 200, {
        ok: true,
        service: 'agy-fleet-hub',
        latestCommit: hubState.latestCommit,
        schemaVersion: hubState.schemaVersion,
        connectedCount: sseClients.size,
        totalNodes: Object.keys(nodesState).length,
        syncMode: 'sse-push+daily-fallback',
        dailyFallbackSeconds: 86400,
        uptimeSeconds: Math.floor((Date.now() - STARTED_AT) / 1000),
      });
    }

    // 2. GitHub Webhook (HMAC-SHA256)
    if (req.method === 'POST' && p === '/api/agy-fleet/github-webhook') {
      const rawBody = await readRequestBody(req);
      return handleWebhookPush(req, rawBody, res);
    }

    // 3. Bootstrap scripts (?token=<fleetToken>&profile=...)
    if (req.method === 'GET' && p === '/api/agy-fleet/bootstrap.ps1') {
      if (!isFleetAuthorized(req, urlObj)) {
        return sendJson(res, 401, { ok: false, error: 'Unauthorized: invalid or missing fleet token' });
      }
      const profileId = urlObj.searchParams.get('profile') || 'oraiokastro-win11';
      return sendText(res, 200, renderBootstrapPs1(profileId), 'text/plain; charset=utf-8', `bootstrap-${profileId}.ps1`);
    }

    if (req.method === 'GET' && p === '/api/agy-fleet/bootstrap.sh') {
      if (!isFleetAuthorized(req, urlObj)) {
        return sendJson(res, 401, { ok: false, error: 'Unauthorized: invalid or missing fleet token' });
      }
      const profileId = urlObj.searchParams.get('profile') || 'kopanos-omarchy';
      return sendText(res, 200, renderBootstrapSh(profileId), 'text/x-shellscript; charset=utf-8', `bootstrap-${profileId}.sh`);
    }

    // 4. SSE Stream (Fleet Token)
    if (req.method === 'GET' && p === '/api/agy-fleet/stream') {
      if (!isFleetAuthorized(req, urlObj)) {
        return sendJson(res, 401, { ok: false, error: 'Unauthorized: invalid fleet token' });
      }
      const qNodeId = urlObj.searchParams.get('nodeId') || '';
      const qHostname = urlObj.searchParams.get('hostname') || '';
      const qOs = urlObj.searchParams.get('os') || '';
      const qPlatform = urlObj.searchParams.get('platform') || '';
      const qCommit = urlObj.searchParams.get('commit') || '';
      const qSchema = urlObj.searchParams.get('schemaVersion') || '';
      const qLabel = urlObj.searchParams.get('label') || '';
      const qLocation = urlObj.searchParams.get('location') || '';

      const nodeId = resolveCanonicalNodeId(qNodeId, qOs, qHostname);
      const clientId = `${nodeId}-${Date.now()}-${crypto.randomBytes(3).toString('hex')}`;
      const nowIso = new Date().toISOString();

      reconcileDuplicateHostname(nodeId, qHostname);
      const existing = nodesState[nodeId] || {};
      nodesState[nodeId] = {
        nodeId,
        label: qLabel || CANONICAL_PROFILES[nodeId]?.label || existing.label || nodeId,
        location: qLocation || CANONICAL_PROFILES[nodeId]?.location || existing.location || 'Remote',
        os: qOs || CANONICAL_PROFILES[nodeId]?.os || existing.os || 'Unknown',
        platform: qPlatform || CANONICAL_PROFILES[nodeId]?.platform || existing.platform || 'linux',
        expectedProfile: CANONICAL_PROFILES[nodeId]?.expectedProfile || existing.expectedProfile || nodeId,
        hostname: qHostname || existing.hostname || null,
        commit: qCommit || existing.commit || null,
        schemaVersion: qSchema || existing.schemaVersion || null,
        online: true,
        connectedSince: nowIso,
        lastSeenAt: nowIso,
        lastSyncAt: existing.lastSyncAt || null,
        lastSyncStatus: existing.lastSyncStatus && existing.lastSyncStatus !== 'PENDING_INSTALL' ? existing.lastSyncStatus : 'CONNECTED',
        lastSyncDurationMs: existing.lastSyncDurationMs || null,
        workspacesSynced: existing.workspacesSynced || 0,
        gatekeeperHealthy: existing.gatekeeperHealthy ?? null,
        clientIp: req.headers['x-forwarded-for'] || req.socket.remoteAddress || null,
      };
      persistNodes();

      res.writeHead(200, {
        'Content-Type': 'text/event-stream',
        'Cache-Control': 'no-cache, no-transform',
        Connection: 'keep-alive',
        'X-Accel-Buffering': 'no',
      });
      res.flushHeaders?.();

      sseClients.set(clientId, { res, nodeId, connectedAt: nowIso });
      const current = readRepoHeadAndSchema();
      writeSseEvent(res, 'sync-state', {
        nodeId,
        commit: current.commit,
        schemaVersion: current.schemaVersion,
        updatedAt: current.updatedAt,
        lastPushAt: hubState.lastPushAt,
      });

      const hbTimer = setInterval(() => {
        try {
          res.write(`: heartbeat ${Date.now()}\n\n`);
          if (nodesState[nodeId]) nodesState[nodeId].lastSeenAt = new Date().toISOString();
        } catch {
          clearInterval(hbTimer);
        }
      }, HEARTBEAT_MS);

      req.on('close', () => {
        clearInterval(hbTimer);
        sseClients.delete(clientId);
        let stillOnline = false;
        for (const c of sseClients.values()) {
          if (c.nodeId === nodeId) {
            stillOnline = true;
            break;
          }
        }
        if (nodesState[nodeId]) {
          nodesState[nodeId].online = stillOnline;
          nodesState[nodeId].lastSeenAt = new Date().toISOString();
          persistNodes();
        }
      });
      return;
    }

    // 5. Edge Daemon ACK (Fleet Token)
    if (req.method === 'POST' && p === '/api/agy-fleet/ack') {
      if (!isFleetAuthorized(req, urlObj)) {
        return sendJson(res, 401, { ok: false, error: 'Unauthorized: invalid fleet token' });
      }
      const rawBody = await readRequestBody(req);
      let body = {};
      try {
        body = JSON.parse(rawBody.toString('utf8') || '{}');
      } catch {
        return sendJson(res, 400, { ok: false, error: 'Invalid JSON body' });
      }
      const nodeId = resolveCanonicalNodeId(body.nodeId, body.os, body.hostname);
      const nowIso = new Date().toISOString();
      reconcileDuplicateHostname(nodeId, body.hostname, body.previousNodeId || null);
      const existing = nodesState[nodeId] || {};
      nodesState[nodeId] = {
        ...existing,
        nodeId,
        label: body.label || CANONICAL_PROFILES[nodeId]?.label || existing.label || nodeId,
        location: body.location || CANONICAL_PROFILES[nodeId]?.location || existing.location || 'Remote',
        os: body.os || CANONICAL_PROFILES[nodeId]?.os || existing.os || 'Unknown',
        platform: body.platform || CANONICAL_PROFILES[nodeId]?.platform || existing.platform || 'linux',
        expectedProfile: CANONICAL_PROFILES[nodeId]?.expectedProfile || existing.expectedProfile || nodeId,
        hostname: body.hostname || existing.hostname || null,
        commit: body.commit || existing.commit || null,
        schemaVersion: body.schemaVersion || existing.schemaVersion || null,
        lastSeenAt: nowIso,
        lastSyncAt: nowIso,
        lastSyncStatus: body.status || 'SYNCED',
        lastSyncDurationMs: typeof body.durationMs === 'number' ? body.durationMs : existing.lastSyncDurationMs,
        workspacesSynced: typeof body.workspacesSynced === 'number' ? body.workspacesSynced : existing.workspacesSynced || 0,
        gatekeeperHealthy: typeof body.gatekeeperHealthy === 'boolean' ? body.gatekeeperHealthy : existing.gatekeeperHealthy,
        clientIp: req.headers['x-forwarded-for'] || req.socket.remoteAddress || existing.clientIp || null,
      };
      persistNodes();
      if (body.commit) {
        resolveAckWaiters(body.commit, nodeId);
      }
      return sendJson(res, 200, { ok: true, node: nodesState[nodeId] });
    }

    // 5b. Release Stale / Mistaken Profile Slot (Fleet Token)
    if (req.method === 'POST' && p === '/api/agy-fleet/release-node') {
      if (!isFleetAuthorized(req, urlObj)) {
        return sendJson(res, 401, { ok: false, error: 'Unauthorized: invalid fleet token' });
      }
      const rawBody = await readRequestBody(req);
      let body = {};
      try {
        body = JSON.parse(rawBody.toString('utf8') || '{}');
      } catch {
        return sendJson(res, 400, { ok: false, error: 'Invalid JSON body' });
      }
      const previousNodeId = String(body.previousNodeId || '').trim();
      const newNodeId = String(body.newNodeId || '').trim();
      const hostname = String(body.hostname || '').trim();
      let released = false;
      if (previousNodeId && previousNodeId !== newNodeId && CANONICAL_PROFILES[previousNodeId]) {
        const prevNode = nodesState[previousNodeId];
        const hasLiveStream = Array.from(sseClients.values()).some((c) => c.nodeId === previousNodeId);
        const sameHost = Boolean(prevNode?.hostname && hostname && prevNode.hostname.trim().toLowerCase() === hostname.toLowerCase());
        if (!hasLiveStream || sameHost || !prevNode?.hostname) {
          if (hasLiveStream) closeStreamsForNode(previousNodeId);
          resetNodeToPending(previousNodeId);
          persistNodes();
          released = true;
        }
      }
      return sendJson(res, 200, { ok: true, released, previousNodeId, nodes: getOrderedNodes() });
    }

    // 6. Fleet Status (Fleet Token OR Admin JWT)
    if (req.method === 'GET' && p === '/api/agy-fleet/status') {
      const fleetOk = isFleetAuthorized(req, urlObj);
      const adminAuth = fleetOk ? { ok: true } : await verifyAdminJwt(req);
      if (!fleetOk && !adminAuth.ok) {
        return sendJson(res, 401, { ok: false, error: 'Unauthorized' });
      }
      const info = readRepoHeadAndSchema();
      return sendJson(res, 200, {
        ok: true,
        latestCommit: info.commit,
        schemaVersion: info.schemaVersion,
        updatedAt: info.updatedAt,
        lastPushAt: hubState.lastPushAt,
        lastWebhookAt: hubState.lastWebhookAt,
        webhookConfigured: Boolean(hubConfig.webhookSecret),
        connectedCount: sseClients.size,
        totalNodes: Object.keys(nodesState).length,
        syncMode: 'sse-push+daily-fallback',
        dailyFallbackSeconds: 86400,
        nodes: getOrderedNodes(),
      });
    }

    // 7. Manual Push Broadcast (Fleet Token OR Admin JWT)
    if (req.method === 'POST' && p === '/api/agy-fleet/publish') {
      const fleetOk = isFleetAuthorized(req, urlObj);
      const adminAuth = fleetOk ? { ok: true } : await verifyAdminJwt(req);
      if (!fleetOk && !adminAuth.ok) {
        return sendJson(res, 401, { ok: false, error: 'Unauthorized' });
      }
      const result = broadcastSyncEvent(fleetOk ? 'cli-publish' : 'admin-publish');
      const uniqueOnlineNodes = new Set(Array.from(sseClients.values()).map((c) => c.nodeId)).size;
      const acks = await waitForAcks(result.commit, uniqueOnlineNodes, 3500);
      return sendJson(res, 200, {
        ok: true,
        ...result,
        acks,
        nodes: getOrderedNodes(),
      });
    }

    // 8. Admin Setup Bundle (STRICTLY Admin JWT)
    if (req.method === 'GET' && p === '/api/agy-fleet/admin/setup-bundle') {
      const adminAuth = await verifyAdminJwt(req);
      if (!adminAuth.ok) {
        return sendJson(res, 401, { ok: false, error: adminAuth.reason || 'Unauthorized' });
      }
      readRepoHeadAndSchema();
      return sendJson(res, 200, { ok: true, ...buildConfigTemplates() });
    }

    // 9. Admin Rotate Fleet Token (STRICTLY Admin JWT)
    if (req.method === 'POST' && p === '/api/agy-fleet/admin/rotate-token') {
      const adminAuth = await verifyAdminJwt(req);
      if (!adminAuth.ok) {
        return sendJson(res, 401, { ok: false, error: adminAuth.reason || 'Unauthorized' });
      }
      hubConfig = {
        ...hubConfig,
        fleetToken: crypto.randomBytes(32).toString('hex'),
      };
      writePrivateJson(CONFIG_FILE, hubConfig);
      updateDevBoxLocalFleetToken(hubConfig.fleetToken);
      for (const client of sseClients.values()) {
        try {
          client.res.end();
        } catch {}
      }
      sseClients.clear();
      readRepoHeadAndSchema();
      return sendJson(res, 200, { ok: true, rotated: true, ...buildConfigTemplates() });
    }

    // 10. Pool 0 Bots & Local Config State (STRICTLY Staging + Admin JWT)
    if (req.method === 'GET' && p === '/api/agy-fleet/bots/state') {
      const auth = await requireStagingAdmin(req);
      if (!auth.ok) {
        return sendJson(res, auth.status || 401, { ok: false, error: auth.reason || 'Unauthorized' });
      }
      return sendJson(res, 200, buildBotsStatePayload());
    }

    // 11. Update Pool 0 Offload Bots Config (STRICTLY Staging + Admin JWT + Strict Allowlist)
    if (req.method === 'PUT' && p === '/api/agy-fleet/bots/config') {
      const auth = await requireStagingAdmin(req);
      if (!auth.ok) {
        return sendJson(res, auth.status || 401, { ok: false, error: auth.reason || 'Unauthorized' });
      }
      const rawBody = await readRequestBody(req);
      let body = {};
      try {
        body = JSON.parse(rawBody.toString('utf8') || '{}');
      } catch {
        return sendJson(res, 400, { ok: false, error: 'Invalid JSON body' });
      }
      const actor = String(auth.user?.username || auth.user?.email || 'admin');
      const validated = validateAndMergeBotsConfig(body, actor);
      if (!validated.ok) {
        return sendJson(res, 400, { ok: false, error: validated.error });
      }
      try {
        writePrivateJsonSafe(BOTS_CONFIG_FILE, validated.config);
      } catch (err) {
        return sendJson(res, 409, { ok: false, error: err.message });
      }
      return sendJson(res, 200, { ok: true, config: validated.config });
    }

    // 12. Execute Pool 0 Bot (STRICTLY Staging + Admin JWT + Strict Allowlists)
    if (req.method === 'POST' && p === '/api/agy-fleet/bots/run') {
      const auth = await requireStagingAdmin(req);
      if (!auth.ok) {
        return sendJson(res, auth.status || 401, { ok: false, error: auth.reason || 'Unauthorized' });
      }
      const rawBody = await readRequestBody(req);
      let body = {};
      try {
        body = JSON.parse(rawBody.toString('utf8') || '{}');
      } catch {
        return sendJson(res, 400, { ok: false, error: 'Invalid JSON body' });
      }
      if (!body || typeof body !== 'object' || Array.isArray(body)) {
        return sendJson(res, 400, { ok: false, error: 'Request body must be a JSON object.' });
      }
      for (const k of Object.keys(body)) {
        if (k !== 'botId' && k !== 'mode' && k !== 'services') {
          return sendJson(res, 400, { ok: false, error: `Unknown run parameter "${k}".` });
        }
      }
      const actor = String(auth.user?.username || auth.user?.email || 'admin');
      const result = await executePool0Bot({
        botId: String(body.botId || '').trim(),
        mode: body.mode !== undefined ? String(body.mode).trim() : undefined,
        services: body.services,
        triggeredBy: actor,
        callerToken: auth.token || '',
      });
      if (!result.ok) {
        return sendJson(res, result.status || 400, { ok: false, error: result.error });
      }
      return sendJson(res, 200, { ok: true, run: result.run });
    }

    // 13. Update Machine-Local Quota Guard Override (STRICTLY Staging + Admin JWT + Allowlisted Fields)
    if (req.method === 'PUT' && p === '/api/agy-fleet/admin/local-routing') {
      const auth = await requireStagingAdmin(req);
      if (!auth.ok) {
        return sendJson(res, auth.status || 401, { ok: false, error: auth.reason || 'Unauthorized' });
      }
      const rawBody = await readRequestBody(req);
      let body = {};
      try {
        body = JSON.parse(rawBody.toString('utf8') || '{}');
      } catch {
        return sendJson(res, 400, { ok: false, error: 'Invalid JSON body' });
      }
      if (!body || typeof body !== 'object' || Array.isArray(body)) {
        return sendJson(res, 400, { ok: false, error: 'Request body must be a JSON object.' });
      }
      const patchSource =
        body.gemini_quota_guard !== undefined && Object.keys(body).length === 1
          ? body.gemini_quota_guard
          : body;
      if (!patchSource || typeof patchSource !== 'object' || Array.isArray(patchSource)) {
        return sendJson(res, 400, { ok: false, error: 'gemini_quota_guard must be a JSON object.' });
      }
      for (const k of Object.keys(patchSource)) {
        if (!LOCAL_ROUTING_ALLOWLIST.has(k)) {
          return sendJson(res, 400, { ok: false, error: `Field "${k}" is not allowlisted for model-routing.local.json.` });
        }
      }
      const routingSnap = readFleetAndLocalRouting();
      const existingLocalRes = readJsonSafeNoSymlink(LOCAL_ROUTING_FILE);
      if (!existingLocalRes.ok && existingLocalRes.error === 'symlink_rejected') {
        return sendJson(res, 409, { ok: false, error: 'Symlink target rejected for model-routing.local.json.' });
      }
      const prevGuard =
        existingLocalRes.ok && existingLocalRes.data?.gemini_quota_guard && typeof existingLocalRes.data.gemini_quota_guard === 'object'
          ? { ...existingLocalRes.data.gemini_quota_guard }
          : {};
      const nextGuard = { ...prevGuard };

      if (patchSource.ctx_hard_limit_tokens !== undefined) {
        const v = patchSource.ctx_hard_limit_tokens;
        if (!Number.isInteger(v) || v < 100000 || v > 1000000) {
          return sendJson(res, 400, { ok: false, error: 'ctx_hard_limit_tokens must be an integer between 100000 and 1000000.' });
        }
        nextGuard.ctx_hard_limit_tokens = v;
      }
      if (patchSource.ctx_warn_tokens !== undefined) {
        const v = patchSource.ctx_warn_tokens;
        if (!Number.isInteger(v) || v < 50000 || v > 950000) {
          return sendJson(res, 400, { ok: false, error: 'ctx_warn_tokens must be an integer between 50000 and 950000.' });
        }
        nextGuard.ctx_warn_tokens = v;
      }
      if (patchSource.warn_threshold_pct !== undefined) {
        const v = patchSource.warn_threshold_pct;
        const reservePct = Number(routingSnap.fleetDefaults.reserve_threshold_pct ?? 10);
        if (!Number.isInteger(v) || v < 15 || v > 60 || v <= reservePct) {
          return sendJson(res, 400, {
            ok: false,
            error: `warn_threshold_pct must be an integer between 15 and 60 and > reserve_threshold_pct (${reservePct}).`,
          });
        }
        nextGuard.warn_threshold_pct = v;
      }
      if (patchSource.reinject_minutes !== undefined) {
        const v = patchSource.reinject_minutes;
        if (!Number.isInteger(v) || v < 5 || v > 60) {
          return sendJson(res, 400, { ok: false, error: 'reinject_minutes must be an integer between 5 and 60.' });
        }
        nextGuard.reinject_minutes = v;
      }

      const effHard = Number(nextGuard.ctx_hard_limit_tokens ?? routingSnap.effective.ctx_hard_limit_tokens);
      const effWarn = Number(nextGuard.ctx_warn_tokens ?? routingSnap.effective.ctx_warn_tokens);
      if (effWarn >= effHard) {
        return sendJson(res, 400, {
          ok: false,
          error: `ctx_warn_tokens (${effWarn}) must be strictly less than ctx_hard_limit_tokens (${effHard}).`,
        });
      }

      const nextDoc = {
        ...(existingLocalRes.ok && existingLocalRes.data && typeof existingLocalRes.data === 'object' ? existingLocalRes.data : {}),
        gemini_quota_guard: nextGuard,
      };
      try {
        writePrivateJsonSafe(LOCAL_ROUTING_FILE, nextDoc);
      } catch (err) {
        return sendJson(res, 409, { ok: false, error: err.message });
      }
      return sendJson(res, 200, { ok: true, localRouting: readFleetAndLocalRouting() });
    }

    // 14. Clear Pool Cooldown Entry or Cache (STRICTLY Staging + Admin JWT)
    if (req.method === 'POST' && p === '/api/agy-fleet/admin/pool-cooldowns/clear') {
      const auth = await requireStagingAdmin(req);
      if (!auth.ok) {
        return sendJson(res, auth.status || 401, { ok: false, error: auth.reason || 'Unauthorized' });
      }
      const rawBody = await readRequestBody(req);
      let body = {};
      try {
        body = JSON.parse(rawBody.toString('utf8') || '{}');
      } catch {
        return sendJson(res, 400, { ok: false, error: 'Invalid JSON body' });
      }
      if (!body || typeof body !== 'object' || Array.isArray(body)) {
        return sendJson(res, 400, { ok: false, error: 'Request body must be a JSON object.' });
      }
      for (const k of Object.keys(body)) {
        if (k !== 'key') return sendJson(res, 400, { ok: false, error: `Unknown parameter "${k}".` });
      }
      const targetKey = typeof body.key === 'string' ? body.key.trim() : '';
      if (targetKey !== '*' && !/^[a-z0-9_]+:[A-Za-z0-9._:/-]{1,100}$/.test(targetKey)) {
        return sendJson(res, 400, { ok: false, error: 'Invalid pool cooldown key.' });
      }
      const cdRes = readJsonSafeNoSymlink(COOLDOWNS_FILE);
      if (!cdRes.ok && cdRes.error === 'symlink_rejected') {
        return sendJson(res, 409, { ok: false, error: 'Symlink target rejected for pool-cooldowns.json.' });
      }
      const nextMap = cdRes.ok && cdRes.data && typeof cdRes.data === 'object' && !Array.isArray(cdRes.data)
        ? { ...cdRes.data }
        : {};
      if (targetKey === '*') {
        for (const k of Object.keys(nextMap)) delete nextMap[k];
      } else {
        delete nextMap[targetKey];
      }
      try {
        writePrivateJsonSafe(COOLDOWNS_FILE, nextMap);
      } catch (err) {
        return sendJson(res, 409, { ok: false, error: err.message });
      }
      return sendJson(res, 200, { ok: true, cleared: targetKey, poolCooldowns: readPoolCooldownsSummary() });
    }

    return sendJson(res, 404, { ok: false, error: 'Not Found' });
  } catch (err) {
    return sendJson(res, 500, { ok: false, error: err.message });
  }
});

// Optional lightweight read-only scheduler for bots configured with schedule='hourly'|'daily'
const lastScheduledRunAt = new Map();
if (process.env.AGY_DISABLE_BOT_SCHEDULER !== '1' && PORT !== 0) {
  setInterval(() => {
    try {
      if (String(process.env.AGY_FLEET_ENV || 'staging').trim().toLowerCase() === 'production') return;
      const cfg = loadOffloadBotsConfig();
      const now = Date.now();
      for (const [botId, spec] of Object.entries(BOT_CATALOG)) {
        const bCfg = cfg.bots?.[botId];
        if (!bCfg || bCfg.enabled !== true) continue;
        const intervalMs = bCfg.schedule === 'hourly' ? 3600000 : bCfg.schedule === 'daily' ? 86400000 : 0;
        if (!intervalMs || runningBots.has(botId)) continue;
        const last = lastScheduledRunAt.get(botId) || 0;
        if (now - last >= intervalMs) {
          lastScheduledRunAt.set(botId, now);
          // Strictly execute read-only defaultMode on unattended schedule
          executePool0Bot({ botId, mode: spec.defaultMode, services: [], triggeredBy: `scheduler:${bCfg.schedule}` });
        }
      }
    } catch {}
  }, 60000).unref();
}

server.listen(PORT, HOST, () => {
  const addr = server.address();
  const actualPort = addr && typeof addr === 'object' ? addr.port : PORT;
  console.log(`🚀 Antigravity Fleet Push Hub listening on http://${HOST}:${actualPort}`);
});
