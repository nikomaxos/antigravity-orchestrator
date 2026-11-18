#!/usr/bin/env node
// =============================================================================
// Antigravity Cross-Platform Lifecycle Hook Runner (`agy-hook.js`)
// =============================================================================
// Zero-dependency Node.js hook runner for Windows (cmd /c) and POSIX (sh -c).
// Executed by `.agents/hooks.json` with cwd = `<repo>/.agents`:
//   node scripts/agy-hook.js protect-enforcement
//   node scripts/agy-hook.js commit-gate [--git-hook]
//   node scripts/agy-hook.js qa-stop-gate
//   node scripts/agy-hook.js preflight
// =============================================================================
'use strict';

const fs = require('fs');
const path = require('path');
const os = require('os');
const http = require('http');
const crypto = require('crypto');
const { execFileSync, spawn } = require('child_process');

const MODE = process.argv[2] || '';
const IS_GIT_HOOK = process.argv.includes('--git-hook');
const isWin = process.platform === 'win32';
const USER_HOME = process.env.HOME || os.homedir() || (isWin ? (process.env.USERPROFILE || 'C:\\Users\\Default') : '/home/nick');

function readStdinUtf8() {
  try {
    return fs.readFileSync(0, 'utf8');
  } catch {
    return '';
  }
}

function readJsonNoBom(filePath) {
  const raw = fs.readFileSync(filePath, 'utf8').replace(/^\uFEFF/, '');
  return JSON.parse(raw);
}

function resolveRepoRoot() {
  const cwd = process.cwd();
  const baseGuess = path.basename(cwd) === '.agents' ? path.resolve(cwd, '..') : cwd;
  try {
    const top = execFileSync('git', ['-C', baseGuess, 'rev-parse', '--show-toplevel'], {
      encoding: 'utf8',
      timeout: 3000,
      windowsHide: true,
      stdio: ['ignore', 'pipe', 'ignore'],
    }).trim();
    if (top) return path.resolve(top);
  } catch {}
  return baseGuess;
}

function runGit(repoRoot, args, trim = true) {
  try {
    const wsUnix = repoRoot.replace(/\\/g, '/');
    const out = execFileSync(
      'git',
      ['-c', 'core.fsmonitor=false', '-c', `safe.directory=${wsUnix}`, '-c', 'safe.directory=*', '-C', repoRoot, ...args],
      {
        encoding: 'utf8',
        maxBuffer: 25 * 1024 * 1024,
        timeout: 4000,
        windowsHide: true,
        stdio: ['ignore', 'pipe', 'pipe'],
      }
    );
    return trim ? out.trim() : out;
  } catch {
    return '';
  }
}

function httpGetJson(urlStr, timeoutMs = 2500) {
  return new Promise((resolve) => {
    const req = http.get(urlStr, { timeout: timeoutMs }, (res) => {
      let raw = '';
      res.on('data', (c) => {
        if (raw.length < 65536) raw += c.toString('utf8');
      });
      res.on('end', () => {
        try {
          resolve({ status: res.statusCode, body: JSON.parse(raw || '{}') });
        } catch {
          resolve({ status: res.statusCode, body: null });
        }
      });
    });
    req.on('timeout', () => {
      req.destroy();
      resolve({ status: 0, body: { errors: ['agy-gatekeeper unreachable (timeout)'] } });
    });
    req.on('error', () => {
      resolve({ status: 0, body: { errors: ['agy-gatekeeper unreachable on 127.0.0.1:18099'] } });
    });
  });
}

function isNonCodeFile(relPath) {
  const f = relPath.replace(/\\/g, '/');
  return (
    f.endsWith('.md') ||
    f.endsWith('.json') ||
    f.endsWith('.txt') ||
    f.startsWith('.agent-state/') ||
    f.startsWith('.agent-reports/') ||
    f === '.last-staging-deploy' ||
    f.startsWith('docs/') ||
    f.startsWith('platform-docs/')
  );
}

function computeLocalWorktreeHash(repoRoot) {
  const excludes = [
    ':(exclude).agent-state',
    ':(exclude).agent-reports',
    ':(exclude).last-staging-deploy',
    ':(exclude)*.md',
    ':(exclude).agents/skills',
    ':(exclude)platform-docs',
    ':(exclude)docs',
  ];
  const diff = runGit(repoRoot, ['diff', 'HEAD', '--', '.', ...excludes], false);
  return crypto.createHash('md5').update(diff, 'utf8').digest('hex');
}

function out(obj) {
  process.stdout.write(JSON.stringify(obj) + '\n');
}

// -----------------------------------------------------------------------------
// 1. protect-enforcement
// -----------------------------------------------------------------------------
function handleProtectEnforcement(input) {
  const toolName = input?.toolCall?.name || '';
  const args = input?.toolCall?.args || {};

  const protectedPatterns = [
    '.agents/hooks.json',
    '.agents/rules/',
    '.agents/scripts/',
    '.agents/skills/',
    'setup-git-hooks.sh',
  ];
  const matchesProtected = (str) => {
    const norm = String(str || '').replace(/[\\/]+/g, '/');
    return protectedPatterns.some((p) => norm.includes(p));
  };

  if (['write_file', 'edit_file', 'write_to_file', 'replace_file_content'].includes(toolName)) {
    const targetFile = String(args.Path || args.TargetFile || '').replace(/[\\/]+/g, '/');
    if (matchesProtected(targetFile)) {
      return out({
        decision: 'force_ask',
        reason:
          '🛡️ PROTECTED: This file is part of the enforcement control plane (.agents/hooks.json, rules/, scripts/, skills/). Modifying it requires explicit human approval.',
      });
    }
    if (targetFile.includes('.agent-state/') || targetFile.includes('.agents/config/')) {
      return out({
        decision: 'deny',
        reason: '🛡️ BLOCKED: Direct write to .agent-state/ or .agents/config/ is forbidden.',
      });
    }
    const content = String(args.Content || args.Replacement || args.CodeContent || args.ReplacementContent || '');
    if (/String\.format\("[^"]*%[0-9]*\.?[0-9]*[fgeFGE]/.test(content) && !content.includes('Locale')) {
      return out({
        decision: 'deny',
        reason:
          '🛡️ ANTI-PATTERN DETECTED: String.format used without explicit Locale. Always use String.format(Locale.US, ...).',
      });
    }
    if (content.includes('nativeQuery') && content.includes('java.sql.Timestamp')) {
      return out({
        decision: 'deny',
        reason:
          '🛡️ ANTI-PATTERN DETECTED: java.sql.Timestamp used near nativeQuery. Always use java.time.Instant and EXTRACT(EPOCH FROM ...).',
      });
    }
  }

  if (toolName === 'read_file' || toolName === 'view_file') {
    const target = String(args.Path || args.AbsolutePath || '').replace(/[\\/]+/g, '/');
    if (target.includes('.gate-secret') || target.includes('agy-gatekeeper/gate.key')) {
      return out({ decision: 'deny', reason: '🛡️ BLOCKED: Reading gate signing secret is forbidden.' });
    }
  }

  if (toolName === 'run_command') {
    const cmd = String(args.CommandLine || '');
    const cmdNorm = cmd.replace(/[\\/]+/g, '/');

    if (
      matchesProtected(cmdNorm) &&
      /(>|>>|\brm\b|\bmv\b|\bcp\b|sed\s+-i|\bchmod\b|\btee\b|\bSet-Content\b|\bOut-File\b|\bRemove-Item\b|\bCopy-Item\b|\bMove-Item\b)/i.test(
        cmdNorm
      )
    ) {
      return out({
        decision: 'force_ask',
        reason: '🛡️ PROTECTED: Command targets enforcement control plane file. Requires explicit human approval.',
      });
    }

    if (cmdNorm.includes('.agent-state/')) {
      const isOfficialRunner =
        /run-(qa|security|regression|vault|docs|skills|codex-review)-gate\.sh|write-security-review\.sh|sync-security-from-review\.sh/.test(
          cmdNorm
        ) && !/sign-gate\.sh/.test(cmdNorm);
      const isAllowedMeta =
        /mkdir\s+-p.*\.agent-state|New-Item.*\.agent-state|git\s+add\s+.*\.agent-state\//.test(cmdNorm) ||
        (/(\bcat\b|\bjq\b|\bhead\b|\btail\b|\bwc\b|\bgrep\b|\bGet-Content\b|node\s+-e).*\.agent-state\//i.test(cmdNorm) &&
          !/(>|>>|\btee\b|\bcp\b|\bmv\b|\brm\b|sed\s+-i|\bSet-Content\b|\bOut-File\b)/i.test(cmdNorm));
      if (!isOfficialRunner && !isAllowedMeta) {
        return out({
          decision: 'deny',
          reason:
            '🛡️ BLOCKED: Direct access to .agent-state/ is restricted. Use the official gate scripts (run-*-gate.sh) instead.',
        });
      }
    }

    if (/(^|[;&|]\s*|\$\(|`|bash\s+|sh\s+|source\s+)([^\s]*\/)?['"]*sign-gate\.sh([\s'"]|$)/.test(cmdNorm)) {
      return out({
        decision: 'deny',
        reason: '🛡️ BLOCKED: Direct invocation of sign-gate.sh is forbidden. Run run-*-gate.sh instead.',
      });
    }

    if (
      /\/api\/gatekeeper\/sign/i.test(cmdNorm) ||
      (/18099/.test(cmdNorm) && /\bPOST\b|--data|-d\s|-Method\s+Post/i.test(cmdNorm))
    ) {
      return out({
        decision: 'deny',
        reason: '🛡️ BLOCKED: Direct HTTP POSTs to :18099 / /api/gatekeeper/sign are forbidden.',
      });
    }

    if (/systemctl\s+(stop|disable|mask|kill|edit)\s+.*(ma|agy)-gatekeeper|Stop-(Service|ScheduledTask).*AntigravityGatekeeper|pkill.*gatekeeper/i.test(cmdNorm)) {
      return out({ decision: 'deny', reason: '🛡️ BLOCKED: Stopping or disabling gatekeeper service is forbidden.' });
    }

    if (/gate\.sec|\.git\/hooks\/\.|\.git\/hooks\/\*|\/etc\/(ma|agy)-gatekeeper\/gate\.key|ProgramData\/agy-gatekeeper\/gate\.key/i.test(cmdNorm)) {
      return out({ decision: 'deny', reason: '🛡️ BLOCKED: Access to gate signing secret is forbidden.' });
    }

    if (/\bgit\s+add\s+((-A|--all|\.)(\s|$))/.test(cmdNorm)) {
      return out({
        decision: 'deny',
        reason: '🛡️ BLOCKED: git add -A / git add . / git add --all is forbidden. Stage explicit file paths.',
      });
    }

    if (/\bgit\s+stash\b/.test(cmdNorm)) {
      return out({ decision: 'deny', reason: '🛡️ BLOCKED: git stash is forbidden.' });
    }

    if (/\bgit\b/.test(cmdNorm) && (/--no-verify/.test(cmdNorm) || /-c\s+core\.hooksPath=/i.test(cmdNorm))) {
      return out({ decision: 'deny', reason: '🛡️ BLOCKED: Bypassing git hooks (--no-verify / core.hooksPath) is forbidden.' });
    }

    if (/(codex|claude|opencode)-orchestrate\.sh/.test(cmdNorm) && /--force-write/.test(cmdNorm)) {
      return out({ decision: 'deny', reason: '🛡️ BLOCKED: --force-write is forbidden in this Single-Writer workspace.' });
    }

    if (/(^|[;&|]\s*)([^\s/]*\/)?codex(\s|$)/.test(cmdNorm)) {
      const isMeta = /\bcodex\s+(--help|-h|--version|-V|login|logout|status|models)(\s|$)/.test(cmdNorm) && !/\b(exec|apply|resume|cloud)\b/.test(cmdNorm);
      const isRo = /\bexec\b/.test(cmdNorm) && /(-s|--sandbox)[\s=]+"?read-only"?/.test(cmdNorm) && !/workspace-write|danger-full-access|dangerously-bypass|--full-auto/.test(cmdNorm);
      if (!isMeta && !isRo) {
        return out({ decision: 'deny', reason: '🛡️ BLOCKED: Codex may ONLY run with explicit -s read-only here.' });
      }
    }

    if (/(^|[;&|]\s*)([^\s/]*\/)?claude(\s|$)/.test(cmdNorm)) {
      const isMeta = /\bclaude\s+(login|logout|auth|status|update|upgrade|--help|-h|--version|-v|-V)(\s|$)/.test(cmdNorm) && !/\s(-p|--print)\b/.test(cmdNorm);
      const isPlan = /permission-mode[\s=]+"?plan"?/.test(cmdNorm) && !/acceptEdits|bypassPermissions|dontAsk|dangerously-skip-permissions/.test(cmdNorm);
      if (!isMeta && !isPlan) {
        return out({ decision: 'deny', reason: '🛡️ BLOCKED: Claude CLI may ONLY run with --permission-mode plan here.' });
      }
    }

    if (/(^|[;&|]\s*)([^\s/]*\/)?opencode(\s|$)/.test(cmdNorm)) {
      const isMeta = /(--help|-h|--version|-v|-V|\bmodels(\s|$))/.test(cmdNorm);
      const isRo = /\brun\b/.test(cmdNorm) && /readonly-auditor/.test(cmdNorm) && !/--auto/.test(cmdNorm);
      if (!isMeta && !isRo) {
        return out({ decision: 'deny', reason: '🛡️ BLOCKED: OpenCode CLI must run with --agent readonly-auditor here.' });
      }
    }
  }

  return out({ decision: 'allow' });
}

// -----------------------------------------------------------------------------
// 2. commit-gate
// -----------------------------------------------------------------------------
async function handleCommitGate(input) {
  const repoRoot = resolveRepoRoot();
  const stateDir = path.join(repoRoot, '.agent-state');
  const cmdLine = IS_GIT_HOOK ? 'git commit' : String(input?.toolCall?.args?.CommandLine || '');

  if (!IS_GIT_HOOK && !/\bgit\s+(commit|push)\b/i.test(cmdLine)) {
    return out({ decision: 'allow' });
  }

  const errors = [];
  const isCommit = /\bgit\s+commit\b/i.test(cmdLine);
  const isPush = /\bgit\s+push\b/i.test(cmdLine);

  if (isCommit && !IS_GIT_HOOK) {
    if (/git\s+commit\b.*(\s|^)(-[a-z0-9]*[noai][a-z0-9]*|--no-verify|--all|--only|--include)(\s|$)/i.test(cmdLine)) {
      errors.push('git commit flags --no-verify/-n/-a/-o/-i/--all/--only/--include are forbidden');
    }
    const restMatch = cmdLine.match(/git\s+commit\b(.*)/i);
    if (restMatch) {
      const tokens = restMatch[1].trim().match(/(?:[^\s"']+|"[^"]*"|'[^']*')+/g) || [];
      const valOpts = new Set([
        '-m', '-F', '-c', '-C', '--message', '--file', '--reedit-message',
        '--reuse-message', '--fixup', '--squash', '--author', '--date', '-u', '--untracked-files',
      ]);
      for (let i = 0; i < tokens.length; i++) {
        const t = tokens[i];
        if (t === '--') {
          if (i + 1 < tokens.length) { errors.push('git commit positional pathspec is forbidden'); break; }
          continue;
        }
        if (t.startsWith('-')) {
          if (valOpts.has(t) && i + 1 < tokens.length) i++;
          continue;
        }
        errors.push('git commit with positional pathspec is forbidden');
        break;
      }
    }
  }

  const checkGateJson = (name) => {
    const f = path.join(stateDir, `${name}.json`);
    if (!fs.existsSync(f)) return null;
    try {
      return readJsonNoBom(f);
    } catch {
      return null;
    }
  };

  const qa = checkGateJson('qa');
  if (!qa || qa.status !== 'PASS') errors.push(`QA status is ${qa?.status || 'MISSING'}`);

  const vault = checkGateJson('vault');
  if (!vault || vault.updated !== true) errors.push('Vault not updated');

  const docs = checkGateJson('docs');
  if (!docs || docs.evaluated !== true) errors.push('Docs not evaluated');

  const skills = checkGateJson('skills');
  if (!skills || skills.evaluated !== true || !['UPDATED', 'NO_UPDATE_NEEDED'].includes(skills.status)) {
    errors.push(`Skills gate invalid (${skills?.status || 'MISSING'})`);
  }

  const reg = checkGateJson('regression');
  if (!reg || !['PASS', 'NOT_APPLICABLE'].includes(reg.status)) {
    errors.push(`Regression: ${reg?.status || 'MISSING'}`);
  }

  const mode = isPush && !isCommit ? 'deploy' : 'commit';
  const gk = await httpGetJson(
    `http://127.0.0.1:18099/api/gatekeeper/verify-status?mode=${mode}&workspace=${encodeURIComponent(repoRoot)}`
  );
  if (gk.status === 0) {
    errors.push('Root Gatekeeper unreachable on 127.0.0.1:18099');
  } else if (gk.status !== 200 || gk.body?.ok !== true) {
    const msgs = Array.isArray(gk.body?.errors) ? gk.body.errors.join('; ') : gk.body?.error || `HTTP ${gk.status}`;
    errors.push(`Root Gatekeeper (${mode}) rejected: ${msgs}`);
  }

  if (isCommit) {
    const stagedAll = runGit(repoRoot, ['diff', '--cached', '--name-only']).split(/\r?\n/).filter(Boolean);
    const hasNonState = stagedAll.some((f) => !f.replace(/\\/g, '/').startsWith('.agent-state/'));
    const hasState = stagedAll.some((f) => f.replace(/\\/g, '/').startsWith('.agent-state/'));
    if (hasNonState && !hasState) {
      errors.push('No .agent-state/ gate files staged');
    }
  }

  if (errors.length > 0) {
    const msg = errors.join('; ');
    if (IS_GIT_HOOK) {
      process.stderr.write(`⛔ BLOCKED BY COMMIT GATE: ${msg}\n`);
      process.exit(1);
    }
    return out({ decision: 'deny', reason: `⛔ BLOCKED: ${msg}` });
  }

  if (IS_GIT_HOOK) {
    process.exit(0);
  }
  return out({ decision: 'allow' });
}

// -----------------------------------------------------------------------------
// 3. qa-stop-gate
// -----------------------------------------------------------------------------
async function handleQaStopGate(input) {
  const termReason = String(input?.terminationReason || '');
  if ((termReason !== 'model_stop' && termReason !== 'NO_TOOL_CALL') || input?.continuationActive === true) {
    return out({ decision: 'stop' });
  }

  const repoRoot = resolveRepoRoot();
  const changed = [
    ...runGit(repoRoot, ['diff', '--name-only']).split(/\r?\n/),
    ...runGit(repoRoot, ['diff', '--cached', '--name-only']).split(/\r?\n/),
    ...runGit(repoRoot, ['ls-files', '--others', '--exclude-standard']).split(/\r?\n/),
  ]
    .map((s) => s.trim())
    .filter(Boolean);

  const codeChanged = Array.from(new Set(changed)).filter((f) => !isNonCodeFile(f));
  if (codeChanged.length === 0) {
    return out({ decision: 'stop' });
  }

  const gk = await httpGetJson(
    `http://127.0.0.1:18099/api/gatekeeper/verify-status?mode=stop&workspace=${encodeURIComponent(repoRoot)}`
  );
  if (gk.status === 0) {
    return out({
      decision: 'continue',
      reason: '⚠️ Cannot stop: Root Gatekeeper unreachable on 127.0.0.1:18099.',
    });
  }
  if (gk.status !== 200 || gk.body?.ok !== true) {
    const msgs = Array.isArray(gk.body?.errors) ? gk.body.errors.join('; ') : gk.body?.error || `HTTP ${gk.status}`;
    return out({
      decision: 'continue',
      reason: `⚠️ Cannot stop: ${msgs}. Complete these gates before stopping.`,
    });
  }

  return out({ decision: 'stop' });
}

// -----------------------------------------------------------------------------
// 4. preflight
// -----------------------------------------------------------------------------
function runGeminiGuard(input, repoRoot) {
  // Automatic rolling 5h/weekly Gemini budget meter + context guard (gemini-budget.js).
  try {
    const guard = require(path.join(__dirname, 'gemini-budget.js'));
    return guard.hookFragment(input || {}, repoRoot);
  } catch {
    return { statusSuffix: '', systemMessages: [] };
  }
}

function handlePreflight(input) {
  const geminiConfigDir = path.join(USER_HOME, '.gemini', 'config');
  const stampFile = path.join(geminiConfigDir, '.last-orchestrator-sync');
  const nowSec = Math.floor(Date.now() / 1000);
  let lastSync = 0;

  if (fs.existsSync(stampFile)) {
    try {
      const mtime = Math.floor(fs.statSync(stampFile).mtimeMs / 1000);
      const val = Number(fs.readFileSync(stampFile, 'utf8').replace(/^\uFEFF/, '').trim());
      lastSync = Number.isFinite(val) && val > mtime ? val : mtime;
    } catch {}
  }

  if (nowSec - lastSync > 86400) {
    try {
      if (isWin) {
        const ps1 = path.join(USER_HOME, '.local', 'bin', 'agy-arch-sync.ps1');
        if (fs.existsSync(ps1)) {
          const child = spawn(
            'powershell.exe',
            ['-NoProfile', '-NonInteractive', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass', '-File', ps1, '-Quiet'],
            { detached: true, stdio: 'ignore', windowsHide: true }
          );
          child.unref();
        }
      } else {
        const sh = path.join(USER_HOME, '.local', 'bin', 'agy-arch-sync');
        if (fs.existsSync(sh)) {
          const child = spawn('bash', [sh, '--quiet'], { detached: true, stdio: 'ignore' });
          child.unref();
        }
      }
    } catch {}
  }

  const repoRoot = resolveRepoRoot();
  const guard = runGeminiGuard(input, repoRoot);
  const guardSteps = (guard.systemMessages || []).map((m) => ({ systemMessage: { systemMessage: m } }));
  const stateDir = path.join(repoRoot, '.agent-state');
  const files = fs.existsSync(stateDir) ? fs.readdirSync(stateDir).filter((f) => f.endsWith('.json')) : [];
  if (files.length === 0) {
    const steps = [...guardSteps];
    if (guard.statusSuffix) steps.unshift({ ephemeralMessage: `🔒 Gates: N/A${guard.statusSuffix}` });
    return out({ injectSteps: steps });
  }

  const readGate = (name) => {
    const p = path.join(stateDir, `${name}.json`);
    if (!fs.existsSync(p)) return null;
    try {
      return readJsonNoBom(p);
    } catch {
      return null;
    }
  };

  const qa = readGate('qa')?.status || 'N/A';
  const reg = readGate('regression')?.status || 'N/A';
  const vaultObj = readGate('vault');
  const vault = vaultObj ? (vaultObj.updated ? 'UPDATED' : 'PENDING') : 'N/A';
  const docsObj = readGate('docs');
  const docs = docsObj ? (docsObj.evaluated ? 'EVALUATED' : 'PENDING') : 'N/A';
  const skillsObj = readGate('skills');
  const skills = skillsObj ? (skillsObj.evaluated ? skillsObj.status || 'EVALUATED' : 'PENDING') : 'PENDING';
  const secObj = readGate('security');
  const security = secObj ? (secObj.status === 'PASS' ? 'REVIEWED' : 'PENDING') : 'N/A';

  let quotaBanner = '';
  const quotaPath = process.env.AGY_GEMINI_QUOTA_FILE || path.join(geminiConfigDir, 'gemini-quota.json');
  if (fs.existsSync(quotaPath)) {
    try {
      const q = readJsonNoBom(quotaPath);
      if (q?.reserve_passthrough_mode === true) {
        quotaBanner = ` | 🚨 GEMINI_QUOTA=${q.gemini_remaining_pct ?? '<10'}% (ZERO-GEMINI PASS-THROUGH RESERVE)`;
      }
    } catch {}
  }

  const msg = `🔒 Active Gates: QA=${qa}, Regression=${reg}, Vault=${vault}, Docs=${docs}, Skills=${skills}, Security=${security}${quotaBanner}${guard.statusSuffix || ''}`;
  return out({ injectSteps: [{ ephemeralMessage: msg }, ...guardSteps] });
}

// -----------------------------------------------------------------------------
// Entrypoint
// -----------------------------------------------------------------------------
(async () => {
  let input = {};
  if (!IS_GIT_HOOK && MODE !== 'preflight') {
    const raw = readStdinUtf8().trim();
    if (raw) {
      try {
        input = JSON.parse(raw.replace(/^\uFEFF/, ''));
      } catch {
        if (MODE === 'commit-gate') {
          return out({ decision: 'deny', reason: '⛔ BLOCKED: Malformed PreToolUse hook input JSON' });
        }
      }
    }
  } else if (MODE === 'preflight') {
    const raw = readStdinUtf8().trim();
    if (raw) {
      try {
        input = JSON.parse(raw.replace(/^\uFEFF/, ''));
      } catch {}
    }
  }

  switch (MODE) {
    case 'protect-enforcement':
      handleProtectEnforcement(input);
      break;
    case 'commit-gate':
      await handleCommitGate(input);
      break;
    case 'qa-stop-gate':
      await handleQaStopGate(input);
      break;
    case 'preflight':
      handlePreflight(input);
      break;
    default:
      out({ decision: 'allow' });
  }
})();
