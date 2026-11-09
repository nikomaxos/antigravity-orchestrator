#!/usr/bin/env node
// =============================================================================
// Antigravity Root-Owned Gatekeeper Enforcement Daemon (agy-gatekeeper.service)
// =============================================================================
// Listens on 127.0.0.1:18099 as root:root.
// Holds the 0600 root:root HMAC secret (/etc/agy-gatekeeper/gate.key and
// <workspace>/.git/hooks/.gate-secret) so unprivileged local users and AI agents
// cannot read the secret, forge gate signatures, or bypass verification.
//
// Dynamically supports ANY Git repository via `body.workspace` or `?workspace=`.
// =============================================================================
const http = require('http');
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const os = require('os');
const { execFileSync } = require('child_process');

const HOST = '127.0.0.1';
const PORT = 18099;
const isWin = process.platform === 'win32';
const IS_ROOT = !isWin && !(process.getuid && process.getuid() !== 0);
const USER_HOME = process.env.HOME || os.homedir() || (isWin ? (process.env.USERPROFILE || 'C:\\Users\\Default') : '/home/nick');

const KEY_PATH = process.env.AGY_GATEKEEPER_KEY_PATH || (
  isWin
    ? (process.env.PROGRAMDATA ? path.join(process.env.PROGRAMDATA, 'agy-gatekeeper', 'gate.key') : path.join(USER_HOME, '.agy-gatekeeper', 'gate.key'))
    : (IS_ROOT ? '/etc/agy-gatekeeper/gate.key' : path.join(USER_HOME, '.config/agy-gatekeeper/gate.key'))
);

const CERTIFIED_COMMITS_PATH = process.env.AGY_GATEKEEPER_COMMITS_PATH || (
  isWin
    ? (process.env.PROGRAMDATA ? path.join(process.env.PROGRAMDATA, 'agy-gatekeeper', 'certified-commits.json') : path.join(USER_HOME, '.agy-gatekeeper', 'certified-commits.json'))
    : (IS_ROOT ? '/var/lib/agy-gatekeeper/certified-commits.json' : path.join(USER_HOME, '.local/share/agy-gatekeeper/certified-commits.json'))
);

const ALLOWED_GATES = new Set([
  'qa',
  'regression',
  'vault',
  'docs',
  'skills',
  'security',
  'codex-review',
  'deploy-audit',
  'last-deploy',
  'staging'
]);

const NON_CODE_WORKTREE_EXCLUDES = [
  ':(exclude).agent-state',
  ':(exclude).agent-reports',
  ':(exclude).last-staging-deploy',
  ':(exclude)*.md',
  ':(exclude).agents/skills',
  ':(exclude)platform-docs',
  ':(exclude)docs'
];

const CODEX_STAGED_EXCLUDES = [
  ':(exclude).agent-state',
  ':(exclude).agent-reports',
  ':(exclude).last-staging-deploy',
  ':(exclude)*.md',
  ':(exclude)platform-docs',
  ':(exclude)docs'
];

function getBashCmd() {
  if (!isWin) return 'bash';
  const candidates = [
    'bash',
    path.join(process.env.ProgramFiles || 'C:\\Program Files', 'Git', 'bin', 'bash.exe'),
    path.join(process.env['ProgramFiles(x86)'] || 'C:\\Program Files (x86)', 'Git', 'bin', 'bash.exe'),
    path.join(process.env.LOCALAPPDATA || '', 'Programs', 'Git', 'bin', 'bash.exe')
  ];
  for (const c of candidates) {
    if (c === 'bash') {
      try {
        execFileSync('bash', ['--version'], { stdio: 'ignore' });
        return 'bash';
      } catch (_) {}
    } else {
      try {
        if (fs.existsSync(c)) return c;
      } catch (_) {}
    }
  }
  return 'bash';
}

function getMasterSecret() {
  let secret = '';
  if (fs.existsSync(KEY_PATH)) {
    try {
      secret = fs.readFileSync(KEY_PATH, 'utf8').trim();
    } catch (_) {}
  }
  if (!secret) {
    secret = crypto.randomBytes(32).toString('hex');
    fs.mkdirSync(path.dirname(KEY_PATH), { recursive: true, mode: 0o700 });
    fs.writeFileSync(KEY_PATH, secret + '\n', { mode: 0o600 });
    if (!isWin) {
      try {
        fs.chownSync(KEY_PATH, 0, 0);
        fs.chmodSync(KEY_PATH, 0o600);
      } catch (_) {}
    }
  }
  return secret;
}

function syncWorkspaceHookSecret(workspace, secret) {
  const hookDir = path.join(workspace, '.git/hooks');
  if (fs.existsSync(hookDir)) {
    const hookKeyPath = path.join(hookDir, '.gate-secret');
    try {
      fs.writeFileSync(hookKeyPath, secret + '\n', { mode: 0o600 });
      if (!isWin) {
        fs.chownSync(hookKeyPath, 0, 0);
        fs.chmodSync(hookKeyPath, 0o600);
      }
    } catch (_) {}
  }
}

function resolveWorkspace(raw) {
  let ws = String(raw || process.cwd()).trim();
  if (isWin) {
    const match = ws.match(/^\/([a-zA-Z])\/(.*)$/);
    if (match) {
      ws = `${match[1].toUpperCase()}:/${match[2]}`;
    }
  }
  ws = path.resolve(ws);
  if (!fs.existsSync(path.join(ws, '.git'))) {
    throw new Error(`Directory is not a Git repository: ${ws}`);
  }
  return ws;
}

function getWorkspaceOwnership(workspace) {
  if (isWin) return { uid: 0, gid: 0 };
  try {
    const st = fs.statSync(workspace);
    return { uid: st.uid, gid: st.gid };
  } catch (_) {
    return { uid: 1000, gid: 1000 };
  }
}

function runGit(workspace, args) {
  try {
    const wsNormalized = isWin ? workspace.replace(/\\/g, '/') : workspace;
    return execFileSync('git', ['-c', 'core.fsmonitor=false', '-c', `safe.directory=${wsNormalized}`, '-c', 'safe.directory=*', '-C', workspace, ...args], {
      encoding: 'utf8',
      maxBuffer: 50 * 1024 * 1024
    });
  } catch (_) {
    return '';
  }
}

function getCurrentHead(workspace) {
  return runGit(workspace, ['rev-parse', 'HEAD']).trim() || 'unknown';
}

function getParentHead(workspace) {
  return runGit(workspace, ['rev-parse', 'HEAD~1']).trim() || 'none';
}

function getCurrentWorktreeHash(workspace) {
  const wsUnix = workspace.replace(/\\/g, '/');
  const bashCmd = getBashCmd();
  try {
    const out = execFileSync(bashCmd, ['-c', `
      cd "${wsUnix}"
      {
        git -c "safe.directory=${wsUnix}" -c "safe.directory=*" diff HEAD -- . ":(exclude).agent-state" ":(exclude).agent-reports" ":(exclude).last-staging-deploy" ":(exclude)*.md" ":(exclude).agents/skills" ":(exclude)platform-docs" ":(exclude)docs" 2>/dev/null || true
        git -c "safe.directory=${wsUnix}" -c "safe.directory=*" ls-files --others --exclude-standard -z -- . ":(exclude).agent-state" ":(exclude).agent-reports" ":(exclude).last-staging-deploy" ":(exclude)*.md" ":(exclude).agents/skills" ":(exclude)platform-docs" ":(exclude)docs" 2>/dev/null | sort -z | xargs -0 -r sha256sum 2>/dev/null || true
      } | md5sum | awk '{print $1}'
    `], { encoding: 'utf8' }).trim();
    if (out) return out;
  } catch (_) {}
  const diff = runGit(workspace, ['diff', 'HEAD', '--', '.', ...NON_CODE_WORKTREE_EXCLUDES]);
  return crypto.createHash('md5').update(diff, 'utf8').digest('hex');
}

function getStagedFiles(workspace) {
  const out = runGit(workspace, ['diff', '--cached', '--name-only', '--', '.', ...CODEX_STAGED_EXCLUDES]).trim();
  return out ? out.split('\n').filter(Boolean).map(f => f.replace(/\\/g, '/')) : [];
}

function getStagedFingerprint(workspace) {
  const diff = runGit(workspace, ['diff', '--cached', '--no-color', '--no-ext-diff', '--', '.', ...CODEX_STAGED_EXCLUDES]);
  return crypto.createHash('sha256').update(diff, 'utf8').digest('hex');
}

function hasCodeChangesForVault(workspace) {
  const unstaged = runGit(workspace, ['diff', 'HEAD', '--name-only']).trim().split('\n').filter(Boolean);
  const staged = runGit(workspace, ['diff', '--cached', '--name-only']).trim().split('\n').filter(Boolean);
  const all = Array.from(new Set([...unstaged, ...staged]));
  // Any file not in .agents/, not in docs/, and not *.md is considered code/config
  return all.some((rawFile) => {
    const f = rawFile.replace(/\\/g, '/');
    return !f.startsWith('.agents/') && !f.startsWith('.agent-state/') && !f.startsWith('docs/') && !f.startsWith('platform-docs/') && !f.endsWith('.md') && !f.endsWith('.txt');
  });
}

function hasActualVaultDiff(workspace) {
  const diffHead = runGit(workspace, ['diff', 'HEAD', '--', '.agents/PROJECT_KNOWLEDGE.md', 'PROJECT_KNOWLEDGE.md', '.agents/knowledge/']).trim();
  const diffCached = runGit(workspace, ['diff', '--cached', '--', '.agents/PROJECT_KNOWLEDGE.md', 'PROJECT_KNOWLEDGE.md', '.agents/knowledge/']).trim();
  return Boolean(diffHead || diffCached);
}

function getPpid(pid) {
  try {
    const status = fs.readFileSync(`/proc/${pid}/status`, 'utf8');
    const m = status.match(/^PPid:\s+(\d+)/m);
    return m ? parseInt(m[1], 10) : 0;
  } catch (_) {
    return 0;
  }
}

function getArgv(pid) {
  try {
    const raw = fs.readFileSync(`/proc/${pid}/cmdline`, 'utf8');
    return raw.split('\0').filter((s) => s.length > 0);
  } catch (_) {
    return [];
  }
}

function resolveProcScriptPath(pid) {
  const argv = getArgv(pid);
  if (argv.length < 2) return '';
  if (argv[1] === '-c' || argv[1].startsWith('-')) return '';
  try {
    const cwd = fs.readlinkSync(`/proc/${pid}/cwd`);
    return fs.realpathSync(path.resolve(cwd, argv[1]));
  } catch (_) {
    return '';
  }
}

function getExpectedRunner(workspace, gate) {
  switch (gate) {
    case 'qa': return path.join(workspace, '.agents/scripts/run-qa-gate.sh');
    case 'regression': return path.join(workspace, '.agents/scripts/run-regression-gate.sh');
    case 'vault': return path.join(workspace, '.agents/scripts/run-vault-gate.sh');
    case 'docs': return path.join(workspace, '.agents/scripts/run-docs-gate.sh');
    case 'skills': return path.join(workspace, '.agents/scripts/run-skills-gate.sh');
    case 'security': return path.join(workspace, '.agents/scripts/run-security-gate.sh');
    case 'codex-review': return path.join(workspace, '.agents/scripts/run-codex-review-gate.sh');
    case 'staging': return path.join(workspace, '.agents/scripts/run-staging-deploy.sh');
    default: return '';
  }
}

function verifyKernelPeerLineage(remotePort, gate, workspace) {
  if (isWin) {
    // Windows does not have /proc/net/tcp. Rely on HMAC-SHA256 and localhost binding.
    return { ok: true };
  }
  const expectedRunner = getExpectedRunner(workspace, gate);
  if (!expectedRunner) {
    return { ok: true };
  }
  const expectedSignGate = path.join(workspace, '.agents/scripts/sign-gate.sh');
  const hexLocal = `0100007F:${Number(remotePort).toString(16).toUpperCase().padStart(4, '0')}`;
  const hexRem = `0100007F:${Number(PORT).toString(16).toUpperCase().padStart(4, '0')}`;

  let inode = '';
  try {
    const tcpLines = fs.readFileSync('/proc/net/tcp', 'utf8').split('\n');
    for (const line of tcpLines) {
      const parts = line.trim().split(/\s+/);
      if (parts.length >= 10 && parts[1] === hexLocal && parts[2] === hexRem) {
        inode = parts[9];
        break;
      }
    }
  } catch (_) {}

  let peerPid = 0;
  if (inode && inode !== '0') {
    const targetLink = `socket:[${inode}]`;
    const procEntries = fs.readdirSync('/proc').filter((d) => /^\d+$/.test(d));
    for (const pidStr of procEntries) {
      const fdDir = `/proc/${pidStr}/fd`;
      try {
        const fds = fs.readdirSync(fdDir);
        for (const fd of fds) {
          try {
            if (fs.readlinkSync(`${fdDir}/${fd}`) === targetLink) {
              peerPid = parseInt(pidStr, 10);
              break;
            }
          } catch (_) {}
        }
        if (peerPid > 0) break;
      } catch (_) {}
    }
  }

  if (peerPid <= 1) {
    return { ok: false, error: 'Could not identify local socket peer process from /proc/net/tcp' };
  }

  const ancestorScripts = [];
  let curPid = peerPid;
  for (let hop = 0; hop < 6; hop++) {
    curPid = getPpid(curPid);
    if (curPid <= 1) break;
    const sp = resolveProcScriptPath(curPid);
    if (sp) ancestorScripts.push(sp);
  }

  const sawSignGate = ancestorScripts.includes(expectedSignGate);
  const sawRunner = ancestorScripts.includes(expectedRunner);
  if (!sawSignGate || !sawRunner) {
    return {
      ok: false,
      error: `Unauthorized process lineage for gate=${gate} in workspace=${workspace} (ancestors=${JSON.stringify(ancestorScripts)}, expected both '${expectedSignGate}' and '${expectedRunner}')`
    };
  }

  return { ok: true };
}

function canonicalizeWithoutHmac(obj) {
  const copy = Object.assign({}, obj);
  delete copy.hmac;
  delete copy.signature;
  try {
    return execFileSync('jq', ['-S', '-c', '.'], {
      input: JSON.stringify(copy),
      encoding: 'utf8'
    }).trim();
  } catch (_) {
    const sortObj = (v) => {
      if (Array.isArray(v)) return v.map(sortObj);
      if (v && typeof v === 'object') {
        return Object.keys(v).sort().reduce((acc, k) => {
          acc[k] = sortObj(v[k]);
          return acc;
        }, {});
      }
      return v;
    };
    return JSON.stringify(sortObj(copy));
  }
}

function computeHmac(canonicalJson, secret) {
  return crypto.createHmac('sha256', secret).update(canonicalJson, 'utf8').digest('hex');
}

function verifyGateFile(workspace, gate, secret) {
  const filePath = path.join(workspace, '.agent-state', `${gate}.json`);
  if (!fs.existsSync(filePath)) {
    return { exists: false, validHmac: false, data: null, error: `${gate}.json missing` };
  }
  try {
    const raw = fs.readFileSync(filePath, 'utf8');
    const data = JSON.parse(raw);
    const storedHmac = data.hmac || '';
    if (!storedHmac) {
      return { exists: true, validHmac: false, data, error: `${gate}.json UNSIGNED` };
    }
    const canonical = canonicalizeWithoutHmac(data);
    const expectedHmac = computeHmac(canonical, secret);
    if (storedHmac !== expectedHmac) {
      return { exists: true, validHmac: false, data, error: `${gate}.json HMAC INVALID` };
    }
    return { exists: true, validHmac: true, data, error: null };
  } catch (err) {
    return { exists: true, validHmac: false, data: null, error: `${gate}.json parse error` };
  }
}

function sendJson(res, statusCode, body) {
  const payload = JSON.stringify(body);
  res.writeHead(statusCode, {
    'Content-Type': 'application/json; charset=utf-8',
    'Content-Length': Buffer.byteLength(payload)
  });
  res.end(payload);
}

function readJsonBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let total = 0;
    req.on('data', (chunk) => {
      total += chunk.length;
      if (total > 5 * 1024 * 1024) {
        reject(new Error('Payload too large'));
        req.destroy();
        return;
      }
      chunks.push(chunk);
    });
    req.on('end', () => {
      try {
        const str = Buffer.concat(chunks).toString('utf8');
        resolve(str ? JSON.parse(str) : {});
      } catch (e) {
        reject(new Error('Invalid JSON body'));
      }
    });
    req.on('error', reject);
  });
}

getMasterSecret();

const server = http.createServer(async (req, res) => {
  try {
    const urlObj = new URL(req.url, `http://${HOST}:${PORT}`);
    const pathname = urlObj.pathname;

    if (req.method === 'GET' && pathname === '/api/gatekeeper/health') {
      return sendJson(res, 200, { status: 'UP', service: 'agy-gatekeeper' });
    }

    if (req.method === 'POST' && pathname === '/api/gatekeeper/sign') {
      const body = await readJsonBody(req);
      let workspace;
      try {
        workspace = resolveWorkspace(body.workspace);
      } catch (err) {
        return sendJson(res, 400, { ok: false, error: err.message });
      }

      let gate = String(body.gate || '').trim();
      gate = gate.replace(/^\.agent-state\//, '').replace(/\.json$/, '');
      if (!ALLOWED_GATES.has(gate)) {
        return sendJson(res, 400, { ok: false, error: `Unsupported gate: ${gate}` });
      }
      if (!body.payload || typeof body.payload !== 'object' || Array.isArray(body.payload)) {
        return sendJson(res, 400, { ok: false, error: 'payload must be a JSON object' });
      }

      const secret = getMasterSecret();
      syncWorkspaceHookSecret(workspace, secret);

      const currentHead = getCurrentHead(workspace);
      const currentWorktreeHash = getCurrentWorktreeHash(workspace);
      const payload = Object.assign({}, body.payload);

      // 1. Objective verification for vault gate
      if (gate === 'vault') {
        const codeChanged = hasCodeChangesForVault(workspace);
        const vaultDiffPresent = hasActualVaultDiff(workspace);
        const actionTaken = payload.action_taken || (payload.updated === true ? 'updated' : '');

        if (actionTaken === 'none_needed') {
          const reason = String(payload.reason || '').trim();
          if (reason.length < 30) {
            return sendJson(res, 422, {
              ok: false,
              error: 'Vault gate rejected: action_taken="none_needed" requires a specific reason >= 30 characters.'
            });
          }
          payload.updated = true;
        } else if (payload.updated === true) {
          if ((codeChanged || actionTaken === 'updated' || payload.require_diff === true) && !vaultDiffPresent) {
            return sendJson(res, 422, {
              ok: false,
              error: 'Vault gate rejected (HTTP 422): payload claims updated=true while code changed, but .agents/PROJECT_KNOWLEDGE.md and .agents/knowledge/*.md have NO git diff HEAD changes!'
            });
          }
        }
      }

      // 2. Kernel peer process lineage check
      const peerCheck = verifyKernelPeerLineage(req.socket.remotePort, gate, workspace);
      if (!peerCheck.ok) {
        return sendJson(res, 403, { ok: false, error: peerCheck.error });
      }

      // 3. Additional objective checks per gate
      if (gate === 'qa' && payload.status === 'PASS') {
        const changedSh = runGit(workspace, ['diff', 'HEAD', '--name-only'])
          .trim()
          .split('\n')
          .filter(Boolean)
          .map((f) => f.replace(/\\/g, '/'))
          .filter((f) => f.endsWith('.sh'));
        for (const shFile of changedSh) {
          const fullSh = path.join(workspace, shFile);
          if (fs.existsSync(fullSh)) {
            try {
              const bashCmd = getBashCmd();
              execFileSync(bashCmd, ['-n', fullSh], { stdio: 'ignore' });
            } catch (_) {
              return sendJson(res, 422, { ok: false, error: `QA gate rejected: bash -n syntax check failed on ${shFile}` });
            }
          }
        }
      } else if (gate === 'skills') {
        if (payload.status === 'UPDATED') {
          const skillDiff = (
            runGit(workspace, ['diff', '--name-only', 'HEAD', '--', '.agents/skills/']) +
            runGit(workspace, ['diff', '--cached', '--name-only', '--', '.agents/skills/']) +
            runGit(workspace, ['diff', '--name-only', 'HEAD~1..HEAD', '--', '.agents/skills/'])
          ).trim();
          if (!skillDiff) {
            return sendJson(res, 422, { ok: false, error: 'Skills gate rejected: status=UPDATED but no .agents/skills/ files were modified' });
          }
        }
      } else if (gate === 'security') {
        if (payload.status !== 'PASS' || !payload.reviewer_agent_id || !Array.isArray(payload.owasp_checklist) || payload.owasp_checklist.length < 3) {
          return sendJson(res, 422, { ok: false, error: 'Security gate rejected: requires status=PASS, reviewer_agent_id, and >=3 owasp_checklist items' });
        }
      } else if (gate === 'codex-review') {
        payload.head = currentHead;
        payload.staged_fingerprint = getStagedFingerprint(workspace);
      }

      payload.tested_head = currentHead;
      payload.worktree_hash = currentWorktreeHash;
      if (gate === 'skills' && !payload.code_hash) {
        payload.code_hash = currentWorktreeHash;
      }
      if (gate === 'security' && !payload.reviewed_head) {
        payload.reviewed_head = currentHead;
      }
      if (!payload.timestamp) {
        payload.timestamp = new Date().toISOString().replace(/\.\d{3}Z$/, 'Z');
      }

      const canonical = canonicalizeWithoutHmac(payload);
      const hmac = computeHmac(canonical, secret);
      const signedObj = JSON.parse(canonical);
      signedObj.hmac = hmac;

      const stateDir = path.join(workspace, '.agent-state');
      fs.mkdirSync(stateDir, { recursive: true });
      if (!isWin) {
        const { uid, gid } = getWorkspaceOwnership(workspace);
        try { fs.chownSync(stateDir, uid, gid); } catch (_) {}
      }

      const targetFile = path.join(stateDir, `${gate}.json`);
      const tmpFile = path.join(stateDir, `.${gate}.json.tmp.${process.pid}.${Date.now()}`);
      fs.writeFileSync(tmpFile, JSON.stringify(signedObj, null, 2) + '\n', { mode: 0o644 });
      if (!isWin) {
        const { uid, gid } = getWorkspaceOwnership(workspace);
        try { fs.chownSync(tmpFile, uid, gid); } catch (_) {}
        try { fs.chmodSync(tmpFile, 0o644); } catch (_) {}
      }
      fs.renameSync(tmpFile, targetFile);

      return sendJson(res, 200, {
        ok: true,
        gate,
        file: `.agent-state/${gate}.json`,
        hmac,
        tested_head: currentHead,
        worktree_hash: currentWorktreeHash
      });
    }

    if (req.method === 'GET' && pathname === '/api/gatekeeper/verify-file') {
      let workspace;
      try {
        workspace = resolveWorkspace(urlObj.searchParams.get('workspace'));
      } catch (err) {
        return sendJson(res, 400, { ok: false, error: err.message });
      }
      let gate = String(urlObj.searchParams.get('gate') || '').trim();
      gate = gate.replace(/^\.agent-state\//, '').replace(/\.json$/, '');
      const secret = getMasterSecret();
      const resCheck = verifyGateFile(workspace, gate, secret);
      return sendJson(res, resCheck.validHmac ? 200 : 412, {
        ok: resCheck.validHmac,
        gate,
        exists: resCheck.exists,
        hmac_valid: resCheck.validHmac,
        error: resCheck.error,
        data: resCheck.data
      });
    }

    if (req.method === 'GET' && pathname === '/api/gatekeeper/verify-status') {
      const mode = urlObj.searchParams.get('mode') || 'commit';
      let workspace;
      try {
        workspace = resolveWorkspace(urlObj.searchParams.get('workspace'));
      } catch (err) {
        return sendJson(res, 400, { ok: false, error: err.message });
      }

      const secret = getMasterSecret();
      const currentHead = getCurrentHead(workspace);
      const parentHead = getParentHead(workspace);
      const currentWorktreeHash = getCurrentWorktreeHash(workspace);
      const emptyMd5 = 'd41d8cd98f00b204e9800998ecf8427e';
      const errors = [];

      const coreGates = ['qa', 'regression', 'vault', 'docs', 'skills'];
      for (const g of coreGates) {
        const vf = verifyGateFile(workspace, g, secret);
        if (!vf.exists || !vf.validHmac) {
          errors.push(vf.error || `${g}.json invalid`);
          continue;
        }
        const d = vf.data;
        if (g === 'qa' && d.status !== 'PASS') {
          errors.push(`QA status is ${d.status || 'PENDING'}`);
        }
        if (g === 'regression' && d.status !== 'PASS' && d.status !== 'NOT_APPLICABLE') {
          errors.push(`Regression status is ${d.status || 'PENDING'}`);
        }
        if (g === 'vault' && d.updated !== true) {
          errors.push('Vault not updated');
        }
        if (g === 'docs' && d.evaluated !== true) {
          errors.push('Docs not evaluated');
        }
        if (g === 'skills' && (d.evaluated !== true || (d.status !== 'UPDATED' && d.status !== 'NO_UPDATE_NEEDED'))) {
          errors.push(`Skills gate invalid (${d.status || 'PENDING'})`);
        }

        const gateHead = d.tested_head || '';
        const gateWt = d.worktree_hash || d.code_hash || '';
        const exactMatch = (gateHead === currentHead && gateWt === currentWorktreeHash);
        const postCommitDeployMatch = (mode === 'deploy' && currentWorktreeHash === emptyMd5 && gateHead === parentHead);
        if (!exactMatch && !postCommitDeployMatch) {
          errors.push(`${g}.json is STALE (expected head=${currentHead.slice(0, 8)} wt=${currentWorktreeHash.slice(0, 8)}, got head=${gateHead.slice(0, 8)} wt=${gateWt.slice(0, 8)})`);
        }
      }

      if (mode === 'commit') {
        const stagedFiles = getStagedFiles(workspace);
        if (stagedFiles.length > 0) {
          const cr = verifyGateFile(workspace, 'codex-review', secret);
          if (!cr.exists || !cr.validHmac) {
            errors.push(cr.error || 'codex-review.json missing/invalid');
          } else {
            const d = cr.data;
            const curFp = getStagedFingerprint(workspace);
            if (d.staged_fingerprint !== curFp) {
              errors.push('codex-review.json is STALE (staged_fingerprint mismatch)');
            } else if (d.status !== 'PASS' && d.status !== 'PASS_FALLBACK') {
              errors.push(`codex-review.json status is ${d.status}`);
            }
          }
        }
      }

      if (mode === 'deploy') {
        const sec = verifyGateFile(workspace, 'security', secret);
        if (!sec.exists || !sec.validHmac) {
          errors.push(sec.error || 'security.json missing/invalid');
        } else {
          const d = sec.data;
          if (d.status !== 'PASS') {
            errors.push(`security.json status is ${d.status}`);
          }
          if ((d.reviewed_head || d.tested_head) !== currentHead) {
            errors.push('security.json reviewed_head does not match current HEAD');
          }
        }
      }

      const ok = errors.length === 0;
      return sendJson(res, ok ? 200 : 412, {
        ok,
        mode,
        workspace,
        head: currentHead,
        worktree_hash: currentWorktreeHash,
        errors
      });
    }

    if (req.method === 'POST' && pathname === '/api/gatekeeper/register-commit') {
      const body = await readJsonBody(req);
      let workspace;
      try {
        workspace = resolveWorkspace(body.workspace);
      } catch (err) {
        return sendJson(res, 400, { ok: false, error: err.message });
      }
      const head = body.head || getCurrentHead(workspace);
      const ts = new Date().toISOString();

      let list = [];
      if (fs.existsSync(CERTIFIED_COMMITS_PATH)) {
        try {
          list = JSON.parse(fs.readFileSync(CERTIFIED_COMMITS_PATH, 'utf8'));
          if (!Array.isArray(list)) list = [];
        } catch (_) {
          list = [];
        }
      }
      list.push({ head, workspace, timestamp: ts });
      if (list.length > 500) {
        list = list.slice(list.length - 500);
      }
      fs.mkdirSync(path.dirname(CERTIFIED_COMMITS_PATH), { recursive: true, mode: 0o755 });
      fs.writeFileSync(CERTIFIED_COMMITS_PATH, JSON.stringify(list, null, 2) + '\n', { mode: 0o644 });
      return sendJson(res, 200, { ok: true, certified_head: head, workspace, timestamp: ts });
    }

    return sendJson(res, 404, { ok: false, error: 'Not found' });
  } catch (err) {
    return sendJson(res, 500, { ok: false, error: err.message || 'Internal server error' });
  }
});

server.listen(PORT, HOST, () => {
  console.log(`[agy-gatekeeper] Root Gatekeeper listening on http://${HOST}:${PORT}`);
});
