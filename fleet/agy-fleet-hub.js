#!/usr/bin/env node
// =============================================================================
// Antigravity Event-Driven Fleet Push Hub (`agy-fleet-hub.js`)
// =============================================================================
// Zero-dependency HTTP/SSE control plane daemon running on DevBox (0.0.0.0:18100).
// - Receives GitHub push webhooks (HMAC-SHA256) and CLI/Admin publish triggers
// - Broadcasts instant SSE `sync` events to all connected workstations
// - Tracks online status, synced commit SHA, schema_version, and Gatekeeper health
// - Serves authenticated bootstrap scripts & setup bundles for:
//     * Windows 11 Pro (Ωραιόκαστρο)
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
const PORT = Number(process.env.AGY_FLEET_PORT || 18100);
const USER_HOME = process.env.HOME || os.homedir() || '/home/nick';
const CONFIG_DIR = process.env.AGY_FLEET_CONFIG_DIR || path.join(USER_HOME, '.config', 'agy-fleet');
const DATA_DIR = process.env.AGY_FLEET_DATA_DIR || path.join(USER_HOME, '.local', 'share', 'agy-fleet');
const CONFIG_FILE = path.join(CONFIG_DIR, 'hub-config.json');
const NODES_FILE = path.join(DATA_DIR, 'nodes.json');
const ADMIN_VERIFY_URL = process.env.AGY_FLEET_ADMIN_VERIFY_URL || 'http://127.0.0.1:8081/api/users/me';
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
  if (hostLow.includes('soti') || osLow.includes('windows')) return 'oraiokastro-win11';
  if (osLow.includes('omarchy') || osLow.includes('arch') || hostLow.includes('kopanos')) return 'kopanos-omarchy';
  if (hostLow.includes('devbox') || rawNodeId === 'devbox') return 'devbox';
  return rawNodeId || `node-${crypto.randomBytes(4).toString('hex')}`;
}

function getOrderedNodes() {
  const connectedCounts = new Map();
  for (const client of sseClients.values()) {
    connectedCounts.set(client.nodeId, (connectedCounts.get(client.nodeId) || 0) + 1);
  }
  const orderedIds = ['devbox', 'oraiokastro-win11', 'kopanos-omarchy'];
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
  const token = extractBearer(req) || urlObj.searchParams.get('token') || '';
  return constantTimeTokenEqual(token, hubConfig.fleetToken);
}

function verifyAdminJwt(req) {
  return new Promise((resolve) => {
    const token = extractBearer(req);
    if (!token) return resolve({ ok: false, reason: 'Missing Authorization Bearer JWT' });

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
              return resolve({ ok: false, reason: `Upstream auth HTTP ${res.statusCode}` });
            }
            try {
              const user = JSON.parse(raw);
              const role = String(user.role || '').toUpperCase();
              if (role === 'SUPER_ADMIN' || role === 'ADMIN') {
                return resolve({ ok: true, user });
              }
              return resolve({ ok: false, reason: `Insufficient role: ${role}` });
            } catch {
              return resolve({ ok: false, reason: 'Invalid auth response JSON' });
            }
          });
        }
      );
      upstream.on('timeout', () => {
        upstream.destroy();
        resolve({ ok: false, reason: 'Upstream auth timeout' });
      });
      upstream.on('error', (err) => {
        resolve({ ok: false, reason: err.message });
      });
      upstream.end();
    } catch (err) {
      resolve({ ok: false, reason: err.message });
    }
  });
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

  const fleetSyncWin11 = JSON.stringify(
    {
      hubUrl: hubConfig.publicHubUrl,
      fleetToken: hubConfig.fleetToken,
      nodeId: 'oraiokastro-win11',
      label: 'Soti-Laptop (Windows 11 Pro)',
      location: 'Ωραιόκαστρο',
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

  const bootstrapUrlWin11 = `${hubConfig.publicHubUrl}/bootstrap.ps1?token=${hubConfig.fleetToken}&profile=oraiokastro-win11`;
  const bootstrapUrlOmarchy = `${hubConfig.publicHubUrl}/bootstrap.sh?token=${hubConfig.fleetToken}&profile=kopanos-omarchy`;

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
      'oraiokastro-win11': {
        nodeId: 'oraiokastro-win11',
        label: 'Windows 11 Pro — Ωραιόκαστρο (Soti-Laptop)',
        location: 'Ωραιόκαστρο',
        os: 'Windows 11 Pro',
        bootstrapUrl: bootstrapUrlWin11,
        bootstrapCommand: `[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; irm "${bootstrapUrlWin11}" | iex`,
        elevatedGatekeeperCommand: `Start-Process powershell -Verb RunAs -ArgumentList '-NoProfile -ExecutionPolicy Bypass -File "' + "$env:USERPROFILE\\Development\\antigravity-orchestrator\\install.ps1" + '"'`,
        cliAuthCommand: `codex login; claude login; opencode auth login`,
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
  const profile = CANONICAL_PROFILES[profileId] || CANONICAL_PROFILES['oraiokastro-win11'];
  const hubUrl = hubConfig.publicHubUrl;
  const token = hubConfig.fleetToken;
  const repoUrl = hubConfig.repoUrl;

  return `# =============================================================================
# Antigravity Workstation Bootstrap — ${profile.label}
# Location: ${profile.location} | Mode: Real-Time SSE Push + 1x Daily Fallback
# =============================================================================
$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$userHome = $HOME
if (-not $userHome) { $userHome = $env:USERPROFILE }

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

# 2. Clone or update antigravity-orchestrator
$devDir = Join-Path $userHome "Development"
$repoDir = Join-Path $devDir "antigravity-orchestrator"
New-Item -ItemType Directory -Path $devDir -Force | Out-Null

if (-not (Test-Path (Join-Path $repoDir ".git"))) {
    Write-Host "📦 Cloning ${repoUrl} -> $repoDir..." -ForegroundColor Cyan
    git clone "${repoUrl}" "$repoDir"
} else {
    Write-Host "🔄 Updating $repoDir from origin/main..." -ForegroundColor Cyan
    $curOrigin = git -C "$repoDir" remote get-url origin 2>$null
    if ($curOrigin -and $curOrigin -like "git@*") {
        git -C "$repoDir" remote set-url origin "${repoUrl}"
    }
    git -C "$repoDir" fetch origin main
    git -C "$repoDir" merge --ff-only origin/main
}

# 3. Write fleet-sync.json BEFORE running install.ps1
$geminiConfigDir = Join-Path $userHome ".gemini\\config"
New-Item -ItemType Directory -Path $geminiConfigDir -Force | Out-Null
$fleetSyncPath = Join-Path $geminiConfigDir "fleet-sync.json"
$fleetCfg = [ordered]@{
    hubUrl = "${hubUrl}"
    fleetToken = "${token}"
    nodeId = "${profile.nodeId}"
    label = "${profile.label}"
    location = "${profile.location}"
    expectedProfile = "${profile.expectedProfile}"
    dailyFallbackSeconds = 86400
}
$fleetCfg | ConvertTo-Json -Depth 5 | Set-Content -Path $fleetSyncPath -Encoding UTF8
Write-Host "   ✓ Saved $fleetSyncPath" -ForegroundColor Green

# 4. Run repository installer (sets rules, Turbo CitC, MCP config, Gatekeeper, Silent Daemon & 1x Daily task)
& (Join-Path $repoDir "install.ps1")

# 5. Send immediate ACK to Staging Fleet Hub
$daemonJs = Join-Path $userHome ".local\\lib\\agy-fleet\\agy-sync-daemon.js"
if ((Get-Command node -ErrorAction SilentlyContinue) -and (Test-Path $daemonJs)) {
    try {
        node "$daemonJs" --once
    } catch {}
}

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host ""
    Write-Host "ℹ️  To enable full Layer 1 NT AUTHORITY\\SYSTEM Gatekeeper TCB lock, run once in Administrator PowerShell:" -ForegroundColor Yellow
    Write-Host "   & '$repoDir\\install.ps1' -SkipClis" -ForegroundColor White
}

Write-Host "✅ ${profile.label} connected to Real-Time SSE Push Hub & 1x Daily fallback!" -ForegroundColor Green
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

# 2. Clone or fast-forward antigravity-orchestrator
DEV_DIR="\${HOME}/Development"
REPO_DIR="\${DEV_DIR}/antigravity-orchestrator"
mkdir -p "\$DEV_DIR"

if [ ! -d "\${REPO_DIR}/.git" ]; then
  echo "📦 Cloning ${repoUrl} -> \${REPO_DIR}..."
  git clone "${repoUrl}" "\$REPO_DIR"
else
  echo "🔄 Updating \${REPO_DIR} from origin/main..."
  git -C "\$REPO_DIR" fetch origin main
  git -C "\$REPO_DIR" merge --ff-only origin/main || true
fi

# 3. Write ~/.gemini/config/fleet-sync.json (mode 0600)
CONFIG_DIR="\${HOME}/.gemini/config"
mkdir -p "\$CONFIG_DIR"
umask 077
cat > "\${CONFIG_DIR}/fleet-sync.json" <<'EOF'
{
  "hubUrl": "${hubUrl}",
  "fleetToken": "${token}",
  "nodeId": "${profile.nodeId}",
  "label": "${profile.label}",
  "location": "${profile.location}",
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

      const existing = nodesState[nodeId] || {};
      nodesState[nodeId] = {
        nodeId,
        label: qLabel || existing.label || nodeId,
        location: qLocation || existing.location || 'Remote',
        os: qOs || existing.os || 'Unknown',
        platform: qPlatform || existing.platform || 'linux',
        expectedProfile: existing.expectedProfile || nodeId,
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
      const existing = nodesState[nodeId] || {};
      nodesState[nodeId] = {
        ...existing,
        nodeId,
        label: body.label || existing.label || nodeId,
        location: body.location || existing.location || 'Remote',
        os: body.os || existing.os || 'Unknown',
        platform: body.platform || existing.platform || 'linux',
        expectedProfile: existing.expectedProfile || nodeId,
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

    return sendJson(res, 404, { ok: false, error: 'Not Found' });
  } catch (err) {
    return sendJson(res, 500, { ok: false, error: err.message });
  }
});

server.listen(PORT, HOST, () => {
  console.log(`🚀 Antigravity Fleet Push Hub listening on http://${HOST}:${PORT}`);
});
