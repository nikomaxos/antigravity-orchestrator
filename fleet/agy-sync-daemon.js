#!/usr/bin/env node
// =============================================================================
// Antigravity Silent Edge Push Daemon (`agy-sync-daemon.js`)
// =============================================================================
// Cross-platform zero-dependency background daemon (Linux / Omarchy / Windows 11).
// Holds an outbound HTTPS SSE connection to DevBox `agy-fleet-hub`:
//   - Receives real-time `sync` push events (1-2s latency)
//   - Auto catch-up when a sleeping laptop wakes up (65s heartbeat watchdog)
//   - Invokes `agy-arch-sync` silently (`windowsHide: true`, zero popups)
//   - Sends live ACK (commit, schema_version, Gatekeeper health) back to Hub
//   - Includes 24h (86400s) daily fallback inside the daemon
// =============================================================================
'use strict';

const http = require('http');
const https = require('https');
const fs = require('fs');
const path = require('path');
const os = require('os');
const { execFileSync, spawn } = require('child_process');

const isWin = process.platform === 'win32';
const USER_HOME = process.env.HOME || os.homedir() || (isWin ? (process.env.USERPROFILE || 'C:\\Users\\Default') : '/home/nick');
const GEMINI_CONFIG_DIR = path.join(USER_HOME, '.gemini', 'config');
const FLEET_CONFIG_PATH = process.env.AGY_FLEET_SYNC_FILE || path.join(GEMINI_CONFIG_DIR, 'fleet-sync.json');
const PID_FILE = path.join(GEMINI_CONFIG_DIR, '.agy-sync-daemon.pid');
const LOG_FILE = path.join(GEMINI_CONFIG_DIR, 'fleet-sync.log');
const ONCE_MODE = process.argv.includes('--once');
const DAILY_FALLBACK_MS = 86400 * 1000;
const HEARTBEAT_WATCHDOG_MS = 65000;

let isSyncing = false;
let pendingCommit = null;
let reconnectDelayMs = 1500;
let activeRequest = null;

function appendLog(line) {
  try {
    fs.mkdirSync(GEMINI_CONFIG_DIR, { recursive: true });
    const entry = `[${new Date().toISOString()}] ${line}\n`;
    if (fs.existsSync(LOG_FILE) && fs.statSync(LOG_FILE).size > 512 * 1024) {
      try {
        fs.renameSync(LOG_FILE, `${LOG_FILE}.1`);
      } catch {}
    }
    fs.appendFileSync(LOG_FILE, entry, 'utf8');
  } catch {}
}

function acquirePidLock() {
  if (ONCE_MODE) return true;
  try {
    fs.mkdirSync(GEMINI_CONFIG_DIR, { recursive: true });
    if (fs.existsSync(PID_FILE)) {
      const oldPid = Number(fs.readFileSync(PID_FILE, 'utf8').trim());
      if (Number.isInteger(oldPid) && oldPid > 0 && oldPid !== process.pid) {
        try {
          process.kill(oldPid, 0);
          return false; // Already running
        } catch {
          // Stale PID
        }
      }
    }
    fs.writeFileSync(PID_FILE, String(process.pid), 'utf8');
    const cleanup = () => {
      try {
        if (fs.existsSync(PID_FILE) && fs.readFileSync(PID_FILE, 'utf8').trim() === String(process.pid)) {
          fs.unlinkSync(PID_FILE);
        }
      } catch {}
    };
    process.on('exit', cleanup);
    process.on('SIGINT', () => {
      cleanup();
      process.exit(0);
    });
    process.on('SIGTERM', () => {
      cleanup();
      process.exit(0);
    });
    return true;
  } catch {
    return true;
  }
}

function readJsonNoBom(filePath) {
  const raw = fs.readFileSync(filePath, 'utf8').replace(/^\uFEFF/, '');
  return JSON.parse(raw);
}

function loadFleetConfig() {
  if (!fs.existsSync(FLEET_CONFIG_PATH)) return null;
  try {
    const cfg = readJsonNoBom(FLEET_CONFIG_PATH);
    if (!cfg.hubUrl || !cfg.fleetToken) return null;
    return cfg;
  } catch {
    return null;
  }
}

function findRepoDir() {
  const candidates = [
    path.join(USER_HOME, 'Development', 'antigravity-orchestrator'),
    path.join(USER_HOME, '.local', 'share', 'antigravity-orchestrator'),
  ];
  if (isWin && process.env.LOCALAPPDATA) {
    candidates.push(path.join(process.env.LOCALAPPDATA, 'antigravity-orchestrator'));
  }
  for (const dir of candidates) {
    if (fs.existsSync(path.join(dir, '.git'))) return dir;
  }
  return candidates[0];
}

function getLocalCommit(repoDir) {
  try {
    if (!fs.existsSync(path.join(repoDir, '.git'))) return null;
    return execFileSync('git', ['-C', repoDir, 'rev-parse', 'HEAD'], {
      encoding: 'utf8',
      timeout: 5000,
      windowsHide: true,
    }).trim();
  } catch {
    return null;
  }
}

function getLocalSchemaVersion() {
  try {
    const routingPath = path.join(GEMINI_CONFIG_DIR, 'model-routing.json');
    if (fs.existsSync(routingPath)) {
      const parsed = readJsonNoBom(routingPath);
      return parsed.schema_version || null;
    }
  } catch {}
  return null;
}

function countRegisteredWorkspaces() {
  try {
    const regPath = path.join(GEMINI_CONFIG_DIR, 'orchestrator-workspaces.json');
    if (fs.existsSync(regPath)) {
      const parsed = readJsonNoBom(regPath);
      if (Array.isArray(parsed)) return parsed.filter(Boolean).length;
      if (typeof parsed === 'string' && parsed.trim()) return 1;
    }
  } catch {}
  return 0;
}

function checkGatekeeperHealth() {
  return new Promise((resolve) => {
    const req = http.get('http://127.0.0.1:18099/api/gatekeeper/health', { timeout: 2000 }, (res) => {
      res.resume();
      resolve(res.statusCode === 200);
    });
    req.on('timeout', () => {
      req.destroy();
      resolve(false);
    });
    req.on('error', () => resolve(false));
  });
}

function runArchSyncQuiet() {
  return new Promise((resolve) => {
    const repoDir = findRepoDir();
    let cmd = '';
    let args = [];
    if (isWin) {
      const localPs1 = path.join(USER_HOME, '.local', 'bin', 'agy-arch-sync.ps1');
      const repoPs1 = path.join(repoDir, 'bin', 'agy-arch-sync.ps1');
      const script = fs.existsSync(repoPs1) ? repoPs1 : localPs1;
      if (!fs.existsSync(script)) {
        return resolve({ ok: false, error: `Missing sync script: ${script}` });
      }
      cmd = 'powershell.exe';
      args = ['-NoProfile', '-NonInteractive', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass', '-File', script, '-Quiet'];
    } else {
      const localSh = path.join(USER_HOME, '.local', 'bin', 'agy-arch-sync');
      const repoSh = path.join(repoDir, 'bin', 'agy-arch-sync');
      const script = fs.existsSync(repoSh) ? repoSh : localSh;
      if (!fs.existsSync(script)) {
        return resolve({ ok: false, error: `Missing sync script: ${script}` });
      }
      cmd = 'bash';
      args = [script, '--quiet'];
    }

    const child = spawn(cmd, args, {
      windowsHide: true,
      stdio: ['ignore', 'ignore', 'pipe'],
      env: {
        ...process.env,
        PATH: isWin
          ? process.env.PATH
          : `${USER_HOME}/.local/share/mise/shims:${USER_HOME}/.local/bin:${USER_HOME}/.opencode/bin:${USER_HOME}/.npm-global/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${process.env.PATH || ''}`,
      },
    });
    let stderr = '';
    child.stderr?.on('data', (d) => {
      if (stderr.length < 4096) stderr += d.toString('utf8');
    });
    child.on('error', (err) => resolve({ ok: false, error: err.message }));
    child.on('close', (code) => resolve({ ok: code === 0, code, stderr: stderr.trim() }));
  });
}

function postJson(urlStr, token, bodyObj) {
  return new Promise((resolve, reject) => {
    const target = new URL(urlStr);
    const client = target.protocol === 'https:' ? https : http;
    const payload = JSON.stringify(bodyObj);
    const req = client.request(
      {
        hostname: target.hostname,
        port: target.port || (target.protocol === 'https:' ? 443 : 80),
        path: target.pathname + target.search,
        method: 'POST',
        headers: {
          Authorization: `Bearer ${token}`,
          'Content-Type': 'application/json',
          'Content-Length': Buffer.byteLength(payload),
        },
        timeout: 8000,
      },
      (res) => {
        let raw = '';
        res.on('data', (c) => {
          if (raw.length < 8192) raw += c.toString('utf8');
        });
        res.on('end', () => resolve({ status: res.statusCode, body: raw }));
      }
    );
    req.on('timeout', () => {
      req.destroy();
      reject(new Error('ACK request timeout'));
    });
    req.on('error', reject);
    req.write(payload);
    req.end();
  });
}

async function sendAck(cfg, status, durationMs) {
  const repoDir = findRepoDir();
  const commit = getLocalCommit(repoDir);
  const schemaVersion = getLocalSchemaVersion();
  const gatekeeperHealthy = await checkGatekeeperHealth();
  const workspacesSynced = countRegisteredWorkspaces();
  const baseHub = cfg.hubUrl.replace(/\/+$/, '');
  try {
    await postJson(`${baseHub}/ack`, cfg.fleetToken, {
      nodeId: cfg.nodeId || os.hostname(),
      label: cfg.label || cfg.nodeId || os.hostname(),
      location: cfg.location || 'Remote',
      os: cfg.os || (isWin ? 'Windows 11' : (os.platform() === 'linux' ? 'Linux' : os.platform())),
      platform: process.platform,
      hostname: os.hostname(),
      commit,
      schemaVersion,
      status,
      durationMs,
      workspacesSynced,
      gatekeeperHealthy,
    });
  } catch (err) {
    appendLog(`ACK error: ${err.message}`);
  }
}

async function triggerSync(cfg, reason = 'push') {
  if (isSyncing) {
    pendingCommit = reason;
    return;
  }
  isSyncing = true;
  const started = Date.now();
  try {
    appendLog(`Starting sync (${reason})`);
    const res = await runArchSyncQuiet();
    const durationMs = Date.now() - started;
    const status = res.ok ? 'SYNCED' : 'ERROR';
    appendLog(`Sync finished: status=${status} durationMs=${durationMs}${res.stderr ? ` err=${res.stderr}` : ''}`);
    await sendAck(cfg, status, durationMs);
  } finally {
    isSyncing = false;
    if (pendingCommit) {
      const nextReason = pendingCommit;
      pendingCommit = null;
      await triggerSync(cfg, nextReason);
    }
  }
}

function connectSseLoop() {
  const cfg = loadFleetConfig();
  if (!cfg) {
    appendLog(`Waiting for ${FLEET_CONFIG_PATH}...`);
    setTimeout(connectSseLoop, 60000);
    return;
  }

  const repoDir = findRepoDir();
  const commit = getLocalCommit(repoDir) || '';
  const schemaVersion = getLocalSchemaVersion() || '';
  const baseHub = cfg.hubUrl.replace(/\/+$/, '');
  const streamUrl = new URL(`${baseHub}/stream`);
  streamUrl.searchParams.set('nodeId', cfg.nodeId || os.hostname());
  streamUrl.searchParams.set('hostname', os.hostname());
  streamUrl.searchParams.set('os', cfg.os || (isWin ? 'Windows 11 Pro' : 'Linux'));
  streamUrl.searchParams.set('platform', process.platform);
  if (cfg.label) streamUrl.searchParams.set('label', cfg.label);
  if (cfg.location) streamUrl.searchParams.set('location', cfg.location);
  if (commit) streamUrl.searchParams.set('commit', commit);
  if (schemaVersion) streamUrl.searchParams.set('schemaVersion', schemaVersion);

  const client = streamUrl.protocol === 'https:' ? https : http;
  let buffer = '';
  let watchdog = null;

  const armWatchdog = (req, socketRes) => {
    clearTimeout(watchdog);
    watchdog = setTimeout(() => {
      appendLog('SSE heartbeat watchdog expired (possible sleep/wake reconnect)');
      try {
        socketRes?.destroy();
        req?.destroy();
      } catch {}
    }, HEARTBEAT_WATCHDOG_MS);
  };

  const scheduleReconnect = () => {
    clearTimeout(watchdog);
    const delay = reconnectDelayMs;
    reconnectDelayMs = Math.min(reconnectDelayMs * 2, 30000);
    setTimeout(connectSseLoop, delay);
  };

  const req = client.request(
    {
      hostname: streamUrl.hostname,
      port: streamUrl.port || (streamUrl.protocol === 'https:' ? 443 : 80),
      path: streamUrl.pathname + streamUrl.search,
      method: 'GET',
      headers: {
        Authorization: `Bearer ${cfg.fleetToken}`,
        Accept: 'text/event-stream',
        'Cache-Control': 'no-cache',
      },
    },
    (res) => {
      if (res.statusCode !== 200) {
        appendLog(`SSE HTTP ${res.statusCode}; retrying...`);
        res.resume();
        scheduleReconnect();
        return;
      }

      reconnectDelayMs = 1500;
      appendLog(`Connected to SSE Push Hub (${baseHub}) as ${cfg.nodeId}`);
      armWatchdog(req, res);

      res.on('data', (chunk) => {
        armWatchdog(req, res);
        buffer += chunk.toString('utf8').replace(/\r\n/g, '\n');
        let sepIdx;
        while ((sepIdx = buffer.indexOf('\n\n')) !== -1) {
          const frame = buffer.slice(0, sepIdx);
          buffer = buffer.slice(sepIdx + 2);
          handleSseFrame(cfg, frame);
        }
      });

      res.on('end', () => {
        appendLog('SSE stream ended; reconnecting...');
        scheduleReconnect();
      });
      res.on('error', (err) => {
        appendLog(`SSE response error: ${err.message}`);
        scheduleReconnect();
      });
    }
  );

  activeRequest = req;
  req.on('error', (err) => {
    appendLog(`SSE connection error: ${err.message}`);
    scheduleReconnect();
  });
  req.end();
}

function handleSseFrame(cfg, frame) {
  let eventName = 'message';
  const dataLines = [];
  for (const line of frame.split('\n')) {
    if (!line || line.startsWith(':')) continue;
    if (line.startsWith('event:')) eventName = line.slice(6).trim();
    else if (line.startsWith('data:')) dataLines.push(line.slice(5).trim());
  }
  if (dataLines.length === 0) return;

  let payload = null;
  try {
    payload = JSON.parse(dataLines.join('\n'));
  } catch {
    return;
  }

  const remoteCommit = payload?.commit;
  if (typeof remoteCommit !== 'string' || !/^[0-9a-f]{40}$/i.test(remoteCommit)) return;

  const localCommit = getLocalCommit(findRepoDir());
  if (eventName === 'sync' || (eventName === 'sync-state' && remoteCommit !== localCommit)) {
    triggerSync(cfg, `${eventName}:${remoteCommit.slice(0, 8)}`).catch((err) => {
      appendLog(`Sync error: ${err.message}`);
    });
  } else if (eventName === 'sync-state' && remoteCommit === localCommit) {
    sendAck(cfg, 'SYNCED', 0).catch(() => {});
  }
}

(async () => {
  if (ONCE_MODE) {
    const cfg = loadFleetConfig();
    if (!cfg) {
      console.error(`Missing ${FLEET_CONFIG_PATH}`);
      process.exit(1);
    }
    await triggerSync(cfg, 'manual-once');
    process.exit(0);
  }

  if (!acquirePidLock()) {
    process.exit(0);
  }

  // Daily fallback timer (86400s) inside daemon
  setInterval(() => {
    const cfg = loadFleetConfig();
    if (cfg) triggerSync(cfg, 'daily-fallback').catch(() => {});
  }, DAILY_FALLBACK_MS);

  connectSseLoop();
})();
