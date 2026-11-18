#!/usr/bin/env node
// =============================================================================
// Antigravity Fleet Push & Sync Stdio MCP Server (`agy-fleet-mcp.js`)
// =============================================================================
// Zero-dependency JSON-RPC 2.0 MCP Server configured in ~/.gemini/config/mcp_config.json.
// Exposes 3 tools to every Antigravity session:
//   - agy_fleet_status          : Live status & commits of DevBox, Windows 11 Pro, Omarchy Linux
//   - agy_fleet_push_sync       : Immediately broadcasts SSE sync push to all workstations
//   - agy_local_architecture_sync : Runs local agy-arch-sync and ACKs to Hub
// =============================================================================
'use strict';

const http = require('http');
const https = require('https');
const fs = require('fs');
const path = require('path');
const os = require('os');
const { spawn } = require('child_process');

const isWin = process.platform === 'win32';
const USER_HOME = process.env.HOME || os.homedir() || (isWin ? (process.env.USERPROFILE || 'C:\\Users\\Default') : '/home/nick');
const GEMINI_CONFIG_DIR = path.join(USER_HOME, '.gemini', 'config');
const FLEET_CONFIG_PATH = process.env.AGY_FLEET_SYNC_FILE || path.join(GEMINI_CONFIG_DIR, 'fleet-sync.json');

const TOOLS = [
  {
    name: 'agy_fleet_status',
    description: 'Inspect real-time online status, git commit SHA, schema_version, and Gatekeeper health of all Antigravity workstations (DevBox, Nick Laptop, Soti-Laptop Windows 11 Pro Oraiokastro, Omarchy Linux Kopanos).',
    inputSchema: {
      type: 'object',
      properties: {},
      additionalProperties: false,
    },
  },
  {
    name: 'agy_fleet_push_sync',
    description: 'Broadcast an immediate event-driven SSE push sync to all connected Antigravity workstations and return per-node ACKs.',
    inputSchema: {
      type: 'object',
      properties: {},
      additionalProperties: false,
    },
  },
  {
    name: 'agy_local_architecture_sync',
    description: 'Run local architecture sync (agy-arch-sync / agy-arch-sync.ps1) on this workstation and report the resulting commit and schema_version.',
    inputSchema: {
      type: 'object',
      properties: {
        force: {
          type: 'boolean',
          description: 'Force workspace script updates even if a workspace has uncommitted changes.',
        },
      },
      additionalProperties: false,
    },
  },
];

function loadFleetConfig() {
  if (!fs.existsSync(FLEET_CONFIG_PATH)) {
    throw new Error(`Fleet config not found at ${FLEET_CONFIG_PATH}. Run workstation bootstrap first.`);
  }
  const parsed = JSON.parse(fs.readFileSync(FLEET_CONFIG_PATH, 'utf8').replace(/^\uFEFF/, ''));
  if (!parsed.hubUrl || !parsed.fleetToken) {
    throw new Error(`Invalid fleet-sync.json at ${FLEET_CONFIG_PATH}`);
  }
  return parsed;
}

function requestJson(method, urlStr, token, bodyObj = null) {
  return new Promise((resolve, reject) => {
    const target = new URL(urlStr);
    const client = target.protocol === 'https:' ? https : http;
    const payload = bodyObj ? JSON.stringify(bodyObj) : null;
    const headers = {
      Authorization: `Bearer ${token}`,
      Accept: 'application/json',
    };
    if (payload) {
      headers['Content-Type'] = 'application/json';
      headers['Content-Length'] = Buffer.byteLength(payload);
    }
    const req = client.request(
      {
        hostname: target.hostname,
        port: target.port || (target.protocol === 'https:' ? 443 : 80),
        path: target.pathname + target.search,
        method,
        headers,
        timeout: 10000,
      },
      (res) => {
        let raw = '';
        res.on('data', (c) => {
          raw += c.toString('utf8');
        });
        res.on('end', () => {
          try {
            const parsed = JSON.parse(raw || '{}');
            if (res.statusCode >= 400) {
              return reject(new Error(parsed.error || `HTTP ${res.statusCode}`));
            }
            resolve(parsed);
          } catch {
            reject(new Error(`Invalid JSON from hub (HTTP ${res.statusCode})`));
          }
        });
      }
    );
    req.on('timeout', () => {
      req.destroy();
      reject(new Error('Fleet hub request timed out'));
    });
    req.on('error', reject);
    if (payload) req.write(payload);
    req.end();
  });
}

function runLocalSync(force = false) {
  return new Promise((resolve) => {
    const repoDir = path.join(USER_HOME, 'Development', 'antigravity-orchestrator');
    let cmd = 'bash';
    let args = [];
    if (isWin) {
      const localPs1 = path.join(USER_HOME, '.local', 'bin', 'agy-arch-sync.ps1');
      const repoPs1 = path.join(repoDir, 'bin', 'agy-arch-sync.ps1');
      const script = fs.existsSync(repoPs1) ? repoPs1 : localPs1;
      cmd = 'powershell.exe';
      args = ['-NoProfile', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass', '-File', script];
      if (force) args.push('-Force');
    } else {
      const localSh = path.join(USER_HOME, '.local', 'bin', 'agy-arch-sync');
      const repoSh = path.join(repoDir, 'bin', 'agy-arch-sync');
      const script = fs.existsSync(repoSh) ? repoSh : localSh;
      cmd = 'bash';
      args = [script];
      if (force) args.push('--force');
    }
    const child = spawn(cmd, args, { windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'] });
    let stdout = '';
    let stderr = '';
    child.stdout?.on('data', (d) => (stdout += d.toString('utf8')));
    child.stderr?.on('data', (d) => (stderr += d.toString('utf8')));
    child.on('error', (err) => resolve({ ok: false, output: err.message }));
    child.on('close', (code) => resolve({ ok: code === 0, code, output: (stdout + '\n' + stderr).trim() }));
  });
}

async function handleToolCall(name, args = {}) {
  if (name === 'agy_fleet_status') {
    const cfg = loadFleetConfig();
    const data = await requestJson('GET', `${cfg.hubUrl.replace(/\/+$/, '')}/status`, cfg.fleetToken);
    return { content: [{ type: 'text', text: JSON.stringify(data, null, 2) }] };
  }

  if (name === 'agy_fleet_push_sync') {
    const cfg = loadFleetConfig();
    const data = await requestJson('POST', `${cfg.hubUrl.replace(/\/+$/, '')}/publish`, cfg.fleetToken, {});
    return { content: [{ type: 'text', text: JSON.stringify(data, null, 2) }] };
  }

  if (name === 'agy_local_architecture_sync') {
    const res = await runLocalSync(Boolean(args?.force));
    return {
      isError: !res.ok,
      content: [{ type: 'text', text: res.output || (res.ok ? 'Local sync completed.' : 'Local sync failed.') }],
    };
  }

  throw new Error(`Unknown tool: ${name}`);
}

function sendResponse(msg) {
  process.stdout.write(JSON.stringify(msg) + '\n');
}

async function handleMessage(msg) {
  if (!msg || typeof msg !== 'object') return;
  const { id, method, params } = msg;

  // Notifications without id don't expect a response
  if (id === undefined || id === null) return;

  try {
    if (method === 'initialize') {
      const requestedProto = params?.protocolVersion || '2024-11-05';
      return sendResponse({
        jsonrpc: '2.0',
        id,
        result: {
          protocolVersion: requestedProto,
          capabilities: { tools: {} },
          serverInfo: { name: 'agy-fleet', version: '1.0.0' },
        },
      });
    }
    if (method === 'ping') {
      return sendResponse({ jsonrpc: '2.0', id, result: {} });
    }
    if (method === 'tools/list') {
      return sendResponse({ jsonrpc: '2.0', id, result: { tools: TOOLS } });
    }
    if (method === 'tools/call') {
      const result = await handleToolCall(params?.name, params?.arguments || {});
      return sendResponse({ jsonrpc: '2.0', id, result });
    }
    return sendResponse({
      jsonrpc: '2.0',
      id,
      error: { code: -32601, message: `Method not found: ${method}` },
    });
  } catch (err) {
    return sendResponse({
      jsonrpc: '2.0',
      id,
      error: { code: -32000, message: err.message },
    });
  }
}

let lineBuf = '';
process.stdin.setEncoding('utf8');
process.stdin.on('data', (chunk) => {
  lineBuf += chunk;
  let nlIdx;
  while ((nlIdx = lineBuf.indexOf('\n')) !== -1) {
    const line = lineBuf.slice(0, nlIdx).trim();
    lineBuf = lineBuf.slice(nlIdx + 1);
    if (!line) continue;
    try {
      const parsed = JSON.parse(line);
      handleMessage(parsed);
    } catch {}
  }
});
