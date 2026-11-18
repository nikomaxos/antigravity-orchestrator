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

// Shell-word tokenizer (splits at `;`, `&&`, `||`, `|`, `&`, `\n`, `(`, `)`, `{`, `}`, `$(`, `!`, `` ` ``)
// while keeping `${VAR}` intact and mid-word quoting like `-c user.name='Test User'` as a single token.
function splitShellTokens(str) {
  const tokens = [];
  let i = 0;
  const n = str.length;
  while (i < n) {
    while (i < n && /[ \t\r]/.test(str[i])) i++;
    if (i >= n) break;
    const two = str.slice(i, i + 2);
    if (two === '&&' || two === '||' || two === '$(') {
      tokens.push({ op: two });
      i += 2;
      continue;
    }
    if ('\n;|&(){}!`'.includes(str[i])) {
      tokens.push({ op: str[i] });
      i += 1;
      continue;
    }
    let tok = '';
    while (i < n && !/[ \t\r\n;|&(){}`]/.test(str[i])) {
      const ch = str[i];
      if (ch === '$' && str[i + 1] === '(') break;
      if (ch === '$' && str[i + 1] === '{') {
        const start = i;
        i += 2;
        let braceDepth = 1;
        while (i < n && braceDepth > 0) {
          if (str[i] === '\\' && i + 1 < n) {
            i += 2;
            continue;
          }
          if (str[i] === '{') braceDepth++;
          else if (str[i] === '}') braceDepth--;
          i++;
        }
        tok += str.slice(start, i);
        continue;
      }
      if (ch === '$' && str[i + 1] === "'") {
        const start = i;
        i += 2;
        while (i < n && str[i] !== "'") {
          if (str[i] === '\\' && i + 1 < n) i += 2;
          else i++;
        }
        if (i < n) i++;
        tok += str.slice(start, i);
      } else if (ch === "'") {
        const start = i++;
        while (i < n && str[i] !== "'") i++;
        if (i < n) i++;
        tok += str.slice(start, i);
      } else if (ch === '"') {
        const start = i++;
        while (i < n && str[i] !== '"') {
          if (str[i] === '\\' && i + 1 < n) {
            i += 2;
            continue;
          }
          if (str[i] === '$' && str[i + 1] === '(') {
            i += 2;
            let pDepth = 1;
            while (i < n && pDepth > 0) {
              if (str[i] === '\\' && i + 1 < n) { i += 2; continue; }
              if (str[i] === '$' && str[i + 1] === "'") { i += 2; while (i < n && str[i] !== "'") { if (str[i] === '\\' && i + 1 < n) i += 2; else i++; } if (i < n) i++; continue; }
              if (str[i] === "'") { i++; while (i < n && str[i] !== "'") i++; if (i < n) i++; continue; }
              if (str[i] === '"') { i++; while (i < n && str[i] !== '"') { if (str[i] === '\\' && i + 1 < n) i++; i++; } if (i < n) i++; continue; }
              if (str[i] === '(') pDepth++;
              else if (str[i] === ')') pDepth--;
              i++;
            }
            continue;
          }
          i++;
        }
        if (i < n) i++;
        tok += str.slice(start, i);
      } else if (ch === '\\' && i + 1 < n) {
        tok += str.slice(i, i + 2);
        i += 2;
      } else {
        tok += ch;
        i++;
      }
    }
    tokens.push({ word: tok });
  }
  return tokens;
}

const GIT_TWO_ARG_OPTS = new Set([
  '-C', '-c', '--git-dir', '--work-tree', '--namespace',
  '--config-env', '--exec-path', '--super-prefix', '--attr-source', '--list-cmds',
]);
const GIT_ZERO_ARG_OPTS = new Set([
  '-p', '-P', '-h', '-v', '-version', '--version', '--help',
  '--paginate', '--no-pager', '--bare', '--no-replace-objects',
  '--literal-pathspecs', '--glob-pathspecs', '--noglob-pathspecs',
  '--icase-pathspecs', '--no-optional-locks', '--no-advice',
  '--html-path', '--man-path', '--info-path',
]);
const GIT_TWO_ARG_PREFIXES = [
  '-C', '-c', '--git-dir=', '--work-tree=', '--namespace=',
  '--config-env=', '--exec-path=', '--super-prefix=', '--attr-source=', '--list-cmds=',
];
const QUOTED_UNWRAP_SKIP_PREV = new Set(['-m', '--message', '-F', '--file', '--author', '--grep', '-S', '-G', '--format', '--pretty', '--title', '--body']);
const QUOTED_UNWRAP_SKIP_CMDS = new Set(['grep', 'egrep', 'fgrep', 'rg', 'ag', 'ack']);
const SHELL_WRAPPER_CMDS = new Set([
  'bash', 'sh', 'zsh', 'dash', 'ksh', 'ash', 'csh', 'tcsh', 'fish',
  'cmd', 'cmd.exe', 'powershell', 'pwsh', 'env', 'xargs', 'sudo', 'timeout', 'nohup', 'eval', 'exec',
]);
const GIT_META_SUBCMDS = new Set([
  'commit', 'tag', 'log', 'shortlog', 'notes', 'rev-list', 'show', 'diff',
]);

function isMetaArgContext(segCmd, gitSub, prevFlagExact) {
  if (!prevFlagExact || SHELL_WRAPPER_CMDS.has(segCmd)) return false;
  if (!QUOTED_UNWRAP_SKIP_PREV.has(prevFlagExact)) return false;
  if (segCmd === 'git' || segCmd === 'git.exe') return GIT_META_SUBCMDS.has(gitSub);
  if (segCmd === 'gh') return true;
  return false;
}

function decodeAnsiCBody(body) {
  return body.replace(/\\(x[0-9a-fA-F]{1,2}|u[0-9a-fA-F]{4}|[0-7]{1,3}|.)/g, (_, esc) => {
    if (esc.startsWith('x') || esc.startsWith('u')) return String.fromCharCode(parseInt(esc.slice(1), 16));
    if (/^[0-7]{1,3}$/.test(esc)) return String.fromCharCode(parseInt(esc, 8));
    const map = { n: '\n', r: '\r', t: '\t', b: '\b', f: '\f', v: '\v', a: '\x07', e: '\x1b', E: '\x1b' };
    return map[esc] ?? esc;
  });
}

// Strip POSIX shell quotes/escapes ($'...', '...', "...", \c) while preserving Windows drive/UNC paths.
function unquoteShellWord(w) {
  const s = String(w || '');
  const isWinPath = /^["']?(?:[A-Za-z]:\\|\\\\)/.test(s);
  let out = '';
  let i = 0;
  while (i < s.length) {
    if (s[i] === '$' && s[i + 1] === "'") {
      i += 2;
      const start = i;
      while (i < s.length && s[i] !== "'") {
        if (s[i] === '\\' && i + 1 < s.length) i += 2;
        else i++;
      }
      out += decodeAnsiCBody(s.slice(start, i));
      if (i < s.length && s[i] === "'") i++;
    } else if (s[i] === "'") {
      i++;
      while (i < s.length && s[i] !== "'") out += s[i++];
      if (i < s.length) i++;
    } else if (s[i] === '"') {
      i++;
      while (i < s.length && s[i] !== '"') {
        if (s[i] === '\\' && i + 1 < s.length && '"\\$`\n'.includes(s[i + 1])) {
          if (s[i + 1] !== '\n') out += s[i + 1];
          i += 2;
        } else {
          out += s[i++];
        }
      }
      if (i < s.length) i++;
    } else if (s[i] === '\\' && i + 1 < s.length && !isWinPath) {
      out += s[i + 1];
      i += 2;
    } else {
      out += s[i++];
    }
  }
  return out;
}

function replaceBalancedDollarParen(str, depth, transformFn = normalizeGitCommand) {
  let out = '';
  let i = 0;
  while (i < str.length) {
    if (str[i] === '$' && str[i + 1] === "'") {
      const start = i;
      i += 2;
      while (i < str.length && str[i] !== "'") {
        if (str[i] === '\\' && i + 1 < str.length) i += 2;
        else i++;
      }
      if (i < str.length) i++;
      out += str.slice(start, i);
      continue;
    }
    if (str[i] === '\\' && i + 1 < str.length) {
      out += str.slice(i, i + 2);
      i += 2;
      continue;
    }
    if (str[i] === '$' && str[i + 1] === '(') {
      const start = i + 2;
      let j = start;
      let pDepth = 1;
      while (j < str.length && pDepth > 0) {
        const ch = str[j];
        if (ch === '\\' && j + 1 < str.length) { j += 2; continue; }
        if (ch === '$' && str[j + 1] === "'") {
          j += 2;
          while (j < str.length && str[j] !== "'") { if (str[j] === '\\' && j + 1 < str.length) j += 2; else j++; }
          if (j < str.length) j++;
          continue;
        }
        if (ch === "'") {
          j++;
          while (j < str.length && str[j] !== "'") j++;
          j++;
          continue;
        }
        if (ch === '"') {
          j++;
          while (j < str.length && str[j] !== '"') {
            if (str[j] === '\\' && j + 1 < str.length) j++;
            j++;
          }
          j++;
          continue;
        }
        if (ch === '(') pDepth++;
        else if (ch === ')') pDepth--;
        j++;
      }
      if (pDepth === 0) {
        const inner = str.slice(start, j - 1);
        out += `$(${transformFn(inner, depth + 1)})`;
        i = j;
        continue;
      }
    }
    out += str[i++];
  }
  return out;
}

const MAX_SHELL_DEPTH = 16;

function normalizeGitSubCmds(str, depth, transformFn = normalizeGitCommand) {
  if (depth > MAX_SHELL_DEPTH || (!str.includes('$(') && !str.includes('`'))) return str;
  const withDollar = str.includes('$(') ? replaceBalancedDollarParen(str, depth, transformFn) : str;
  return withDollar.replace(/`([^`]*)`/g, (_, inner) => `\`${transformFn(inner, depth + 1)}\``);
}

function canonicalShell(cmd, depth = 0) {
  const raw = String(cmd || '');
  if (depth > MAX_SHELL_DEPTH || !raw) return raw;
  const tokens = splitShellTokens(raw);
  const parts = [];
  let segCmd = '';
  let gitSub = '';
  let gitSkipNext = false;
  let prevWord = '';
  for (const t of tokens) {
    if (t.op) {
      parts.push(t.op === '\n' ? '\n' : t.op);
      segCmd = '';
      gitSub = '';
      gitSkipNext = false;
      prevWord = '';
      continue;
    }
    const rawTok = t.word;
    const prevUnq = unquoteShellWord(prevWord);
    const isQuotedWrap =
      rawTok.length >= 2 &&
      ((rawTok.startsWith('"') && rawTok.endsWith('"')) || (rawTok.startsWith("'") && rawTok.endsWith("'")));
    if (
      depth < MAX_SHELL_DEPTH &&
      isQuotedWrap &&
      !isMetaArgContext(segCmd, gitSub, prevUnq) &&
      !QUOTED_UNWRAP_SKIP_CMDS.has(segCmd)
    ) {
      const q = rawTok[0];
      const inner = q === '"' ? rawTok.slice(1, -1).replace(/\\"/g, '"') : rawTok.slice(1, -1);
      if (/\s/.test(inner)) {
        const normInner = canonicalShell(inner, depth + 1);
        parts.push(`${q}${normInner}${q}`);
        prevWord = rawTok;
        continue;
      }
    }
    let w = normalizeGitSubCmds(rawTok, depth, canonicalShell);
    const unqW = unquoteShellWord(w);
    const baseW = unqW.split(/[\\/]/).pop().toLowerCase();
    if (!segCmd && !/^[A-Za-z_][A-Za-z0-9_]*=/.test(unqW)) {
      segCmd = baseW;
    } else if ((segCmd === 'git' || segCmd === 'git.exe') && !gitSub) {
      if (gitSkipNext) {
        gitSkipNext = false;
      } else if (GIT_TWO_ARG_OPTS.has(unqW)) {
        gitSkipNext = true;
      } else if (GIT_TWO_ARG_PREFIXES.some((p) => unqW.startsWith(p)) || GIT_ZERO_ARG_OPTS.has(unqW)) {
        // skip global git option
      } else if (!unqW.startsWith('-')) {
        gitSub = unqW.toLowerCase();
      }
    }
    if (!/\$\(|`|\$\{/.test(w)) {
      parts.push(/\s/.test(unqW) || unqW === '' ? `"${unqW.replace(/"/g, '')}"` : unqW);
    } else {
      parts.push(w);
    }
    prevWord = w;
  }
  return parts
    .map((p, idx) => (p === '\n' ? '\n' : idx === 0 || parts[idx - 1] === '\n' ? p : ` ${p}`))
    .join('')
    .trim();
}

// Replace non-executable search/metadata literals (`grep "git commit"`, `rg 'git commit -n'`,
// `git commit -m "..."`, `git log --grep "..."`) with `""` while preserving any `$(...)` or backticks.
// Never strips args to shell wrappers (`bash -c -m ...`) or write subcommands (`git checkout -m ...`).
function stripNonExecSearchLiterals(cmd, depth = 0) {
  const raw = String(cmd || '');
  if (depth > MAX_SHELL_DEPTH || !raw) return raw;
  const tokens = splitShellTokens(raw);
  const parts = [];
  let segCmd = '';
  let gitSub = '';
  let gitSkipNext = false;
  let prevFlag = '';
  for (const t of tokens) {
    if (t.op) {
      parts.push(t.op === '\n' ? '\n' : t.op);
      segCmd = '';
      gitSub = '';
      gitSkipNext = false;
      prevFlag = '';
      continue;
    }
    let w = t.word;
    const unq = unquoteShellWord(w);
    const base = unq.split(/[\\/]/).pop().toLowerCase();
    if (!segCmd && !/^[A-Za-z_][A-Za-z0-9_]*=/.test(unq)) {
      segCmd = base;
    } else if ((segCmd === 'git' || segCmd === 'git.exe') && !gitSub) {
      if (gitSkipNext) {
        gitSkipNext = false;
      } else if (GIT_TWO_ARG_OPTS.has(unq)) {
        gitSkipNext = true;
      } else if (GIT_TWO_ARG_PREFIXES.some((p) => unq.startsWith(p)) || GIT_ZERO_ARG_OPTS.has(unq)) {
        // skip global git option
      } else if (!unq.startsWith('-')) {
        gitSub = unq.toLowerCase();
      }
    }
    const isSearchCmd = QUOTED_UNWRAP_SKIP_CMDS.has(segCmd);
    const isMetaPrev = isMetaArgContext(segCmd, gitSub, prevFlag);
    const isMetaEqCtx =
      isSearchCmd || segCmd === 'gh' || ((segCmd === 'git' || segCmd === 'git.exe') && GIT_META_SUBCMDS.has(gitSub));
    const hasExecSubst = !/^'[^']*'$/.test(w) && (/\$\(/.test(w) || /`/.test(w) || /\$\{/.test(w));
    if (
      !hasExecSubst &&
      ((isMetaPrev && w) ||
        (isSearchCmd && ((w.startsWith('"') && w.endsWith('"')) || (w.startsWith("'") && w.endsWith("'")))))
    ) {
      w = '""';
    } else if (isMetaEqCtx && /^--(?:grep|format|pretty|title|body|author|message)=/i.test(unq) && !hasExecSubst) {
      w = `${unq.split('=')[0]}=""`;
    } else if (
      depth < MAX_SHELL_DEPTH &&
      SHELL_WRAPPER_CMDS.has(segCmd) &&
      w.length >= 2 &&
      ((w.startsWith('"') && w.endsWith('"')) || (w.startsWith("'") && w.endsWith("'"))) &&
      /\s/.test(w)
    ) {
      const q = w[0];
      const inner = q === '"' ? w.slice(1, -1).replace(/\\"/g, '"') : w.slice(1, -1);
      w = `${q}${stripNonExecSearchLiterals(inner, depth + 1)}${q}`;
    }
    parts.push(w);
    prevFlag = unq;
  }
  return parts
    .map((p, idx) => (p === '\n' ? '\n' : idx === 0 || parts[idx - 1] === '\n' ? p : ` ${p}`))
    .join('')
    .trim();
}

// Strip git GLOBAL options that may precede the subcommand (`git -C . commit`, `"g"it commit`,
// `g\it commit`, `(git -C . commit)`, `$(git -C . commit)`, `!git -C . commit`,
// `bash -c "git -C . commit"`, `git -c user.name='A B' commit`, `git --attr-source HEAD commit`,
// `git "commit" -n`) using shell-word tokens + canonical unquoting, plus recursion inside substitutions.
function normalizeGitCommand(cmd, depth = 0) {
  const raw = String(cmd || '');
  if (!/git/i.test(raw.replace(/["'\\]/g, '')) && !raw.includes("$'")) return raw;
  const tokens = splitShellTokens(raw);
  const outParts = [];
  let segCmd = '';
  let gitSub = '';
  let prevWord = '';
  let i = 0;
  const pushWord = (text) => {
    outParts.push(
      outParts.length && !outParts[outParts.length - 1].endsWith(' ') && outParts[outParts.length - 1] !== '\n'
        ? ` ${text}`
        : text
    );
  };
  while (i < tokens.length) {
    if (tokens[i].op) {
      outParts.push(tokens[i].op === '\n' ? '\n' : ` ${tokens[i].op} `);
      segCmd = '';
      gitSub = '';
      prevWord = '';
      i++;
      continue;
    }
    const rawTok = tokens[i].word;
    const rawIsQuotedWrap =
      rawTok.length >= 2 &&
      ((rawTok.startsWith('"') && rawTok.endsWith('"')) || (rawTok.startsWith("'") && rawTok.endsWith("'")));
    if (
      depth < MAX_SHELL_DEPTH &&
      rawIsQuotedWrap &&
      !isMetaArgContext(segCmd, gitSub, prevWord) &&
      !QUOTED_UNWRAP_SKIP_CMDS.has(segCmd)
    ) {
      const q = rawTok[0];
      const rawInner = rawTok.slice(1, -1);
      const inner = q === '"' ? rawInner.replace(/\\"/g, '"') : rawInner;
      if (/\s/.test(inner)) {
        const normInner = /git/i.test(inner.replace(/["'\\]/g, '')) || inner.includes("$'")
          ? normalizeGitCommand(inner, depth + 1)
          : inner;
        pushWord(`${q}${normInner}${q}`);
        prevWord = unquoteShellWord(rawTok);
        i++;
        continue;
      }
    }
    let w = normalizeGitSubCmds(rawTok, depth);
    const unq = unquoteShellWord(w);
    const base = unq.split(/[\\/]/).pop().toLowerCase();
    if (!segCmd && !/^[A-Za-z_][A-Za-z0-9_]*=/.test(unq)) {
      segCmd = base;
    }
    if (!QUOTED_UNWRAP_SKIP_CMDS.has(segCmd) && (base === 'git' || base === 'git.exe')) {
      pushWord('git');
      i++;
      while (i < tokens.length && tokens[i].word) {
        const optRaw = tokens[i].word;
        const opt = unquoteShellWord(optRaw);
        if (GIT_TWO_ARG_OPTS.has(opt)) {
          i++;
          if (i < tokens.length && tokens[i].word) i++;
          continue;
        }
        if (GIT_TWO_ARG_PREFIXES.some((p) => opt.startsWith(p))) {
          i++;
          continue;
        }
        if (GIT_ZERO_ARG_OPTS.has(opt)) {
          i++;
          continue;
        }
        break;
      }
      if (i < tokens.length && tokens[i].word) {
        const sub = unquoteShellWord(normalizeGitSubCmds(tokens[i].word, depth));
        outParts.push(` ${sub}`);
        gitSub = sub.toLowerCase();
        prevWord = sub;
        i++;
      } else {
        prevWord = 'git';
      }
      continue;
    }
    pushWord(w);
    prevWord = unq;
    i++;
  }
  return outParts.join('').trim();
}

// Remove `-m <msg>` / `--message <msg>` payloads ONLY in `git commit/tag/...` context and
// ONLY when substitution-free (`$(...)`, `` `...` ``, `${...}` are never stripped;
// never strips `-m` on `bash -c -m ...` or `git checkout -m ...`).
function stripCommitMessageArgs(cmd, depth = 0) {
  const raw = String(cmd || '');
  if (depth > MAX_SHELL_DEPTH || (!/-m\b|--message\b/i.test(raw) && !/bash|sh|eval/i.test(raw))) return raw;
  const tokens = splitShellTokens(raw);
  const parts = [];
  let segCmd = '';
  let gitSub = '';
  let gitSkipNext = false;
  let expectMsgVal = false;
  for (const t of tokens) {
    if (t.op) {
      parts.push(t.op === '\n' ? '\n' : t.op);
      segCmd = '';
      gitSub = '';
      gitSkipNext = false;
      expectMsgVal = false;
      continue;
    }
    let w = t.word;
    const unq = unquoteShellWord(w);
    const hasExecSubst = !/^'[^']*'$/.test(w) && (/\$\(/.test(w) || /`/.test(w) || /\$\{/.test(w));
    if (expectMsgVal) {
      expectMsgVal = false;
      parts.push(hasExecSubst ? w : '""');
      continue;
    }
    const base = unq.split(/[\\/]/).pop().toLowerCase();
    if (!segCmd && !/^[A-Za-z_][A-Za-z0-9_]*=/.test(unq)) {
      segCmd = base;
    } else if ((segCmd === 'git' || segCmd === 'git.exe') && !gitSub) {
      if (gitSkipNext) {
        gitSkipNext = false;
      } else if (GIT_TWO_ARG_OPTS.has(unq)) {
        gitSkipNext = true;
      } else if (GIT_TWO_ARG_PREFIXES.some((p) => unq.startsWith(p)) || GIT_ZERO_ARG_OPTS.has(unq)) {
        // skip global git option
      } else if (!unq.startsWith('-')) {
        gitSub = unq.toLowerCase();
      }
    }
    const inGitMsg = (segCmd === 'git' || segCmd === 'git.exe') && (!gitSub || GIT_META_SUBCMDS.has(gitSub));
    if (inGitMsg && (unq === '-m' || unq === '--message')) {
      expectMsgVal = true;
      parts.push(w);
      continue;
    }
    if (inGitMsg && /^--message=/i.test(unq) && !hasExecSubst) {
      parts.push('--message=""');
      continue;
    }
    if (
      depth < MAX_SHELL_DEPTH &&
      SHELL_WRAPPER_CMDS.has(segCmd) &&
      w.length >= 2 &&
      ((w.startsWith('"') && w.endsWith('"')) || (w.startsWith("'") && w.endsWith("'"))) &&
      /\s/.test(w)
    ) {
      const q = w[0];
      const inner = q === '"' ? w.slice(1, -1).replace(/\\"/g, '"') : w.slice(1, -1);
      w = `${q}${stripCommitMessageArgs(inner, depth + 1)}${q}`;
    }
    parts.push(w);
  }
  return parts
    .map((p, idx) => (p === '\n' ? '\n' : idx === 0 || parts[idx - 1] === '\n' ? p : ` ${p}`))
    .join('')
    .trim();
}
// Path canonicalization for protected-path matching: unify separators, drop `./` segments and
// duplicate slashes, case-fold (Windows/macOS are case-insensitive), and resolve symlinks for
// absolute existing paths so `.agents/./scripts`, `.AGENTS\Scripts` and symlinks cannot evade.
function normPath(p) {
  let s = String(p || '');
  try {
    if (s && path.isAbsolute(s) && fs.existsSync(s)) s = fs.realpathSync(s);
  } catch {}
  s = s.replace(/[\\/]+/g, '/');
  let prev;
  do {
    prev = s;
    s = s.replace(/\/\.(?=\/)/g, '').replace(/(^|[\s"'=])\.\//g, '$1');
  } while (s !== prev);
  return s.toLowerCase();
}

const PROTECTED_PATH_RE =
  /(?:^|[\/"'\s=:(])(?:\.agents\/(?:hooks\.json|(?:rules|scripts|skills)(?=$|[\/"'\s);&|]))|setup-git-hooks\.sh(?=$|[\/"'\s);&|]))/i;
const AGENT_CONFIG_PATH_RE = /(?:^|[\/"'\s=:(])\.agents\/config(?=$|[\/"'\s);&|])/i;
const AGENT_STATE_PATH_RE = /(?:^|[\/"'\s=:(])\.agent-state(?=$|[\/"'\s);&|])/i;
const HARD_GIT_CFG_RE =
  /(?:^|[\s"'=/~:(])(?:\.git\/(?:hooks|config|info\/attributes)(?=$|[\/"'\s);&|])|\.gitconfig(?=$|[\/"'\s);&|])|git\/config(?=$|[\/"'\s);&|])|\/etc\/gitconfig(?=$|[\/"'\s);&|]))/i;
const HAS_WRITE_OR_LINK_VERB_RE =
  /(>|>>|\brm\b|\bmv\b|\bcp\b|sed\s+-i|\bchmod\b|\bchown\b|\btee\b|\btruncate\b|\bdd\b|\bln\b|\binstall\b|\bSet-Content\b|\bOut-File\b|\bAdd-Content\b|\bRemove-Item\b|\bCopy-Item\b|\bMove-Item\b)/i;

function resolvePathWithAncestors(rawPath, repoRoot) {
  let p = String(rawPath || '').trim().replace(/^["']|["']$/g, '');
  if (!p || /^[a-z]+:\/\//i.test(p)) return '';
  if (p === '~') p = USER_HOME;
  else if (/^~[\\/]/.test(p)) p = path.join(USER_HOME, p.slice(2));
  if (/^[A-Za-z]:[\\/]/.test(p) || p.startsWith('\\\\')) return normPath(p);
  const base = repoRoot || resolveRepoRoot();
  let cur = path.resolve(base, p);
  const tail = [];
  for (let i = 0; i < 16; i++) {
    try {
      if (fs.existsSync(cur)) {
        const real = fs.realpathSync(cur);
        const joined = tail.length ? path.join(real, ...tail.reverse()) : real;
        return normPath(joined);
      }
      const lst = fs.lstatSync(cur);
      if (lst.isSymbolicLink()) {
        const linkTarget = path.resolve(path.dirname(cur), fs.readlinkSync(cur));
        const joined = tail.length ? path.join(linkTarget, ...tail.reverse()) : linkTarget;
        return normPath(joined);
      }
    } catch {}
    const parent = path.dirname(cur);
    if (parent === cur) break;
    tail.push(path.basename(cur));
    cur = parent;
  }
  return normPath(cur);
}

function globSegMatches(pSeg, tSeg) {
  if (!pSeg || !tSeg) return false;
  if (tSeg.startsWith('.') && !pSeg.startsWith('.') && !pSeg.startsWith('[')) {
    return false;
  }
  let re = '^';
  let i = 0;
  while (i < pSeg.length) {
    const ch = pSeg[i];
    if (ch === '*') {
      re += '[^/]*';
      i++;
    } else if (ch === '?') {
      re += '[^/]';
      i++;
    } else if (ch === '[') {
      const close = pSeg.indexOf(']', i + 1);
      if (close > i + 1) {
        let body = pSeg.slice(i + 1, close);
        if (body.startsWith('!')) body = '^' + body.slice(1);
        re += `[${body}]`;
        i = close + 1;
        continue;
      }
      re += '\\[';
      i++;
    } else {
      re += ch.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
      i++;
    }
  }
  re += '$';
  try {
    return new RegExp(re, 'i').test(tSeg);
  } catch {
    return false;
  }
}

function globSegPathMatches(pSegs, tSegs, allowDirPrefix) {
  if (!pSegs.length || !tSegs.length) return false;
  if (pSegs.includes('**')) {
    const matchRec = (pi, ti) => {
      if (pi === pSegs.length) return ti === tSegs.length || (allowDirPrefix && ti >= tSegs.length);
      if (pSegs[pi] === '**') {
        for (let k = ti; k <= tSegs.length; k++) {
          if (k > ti && tSegs[k - 1].startsWith('.')) break;
          if (matchRec(pi + 1, k)) return true;
        }
        return false;
      }
      if (ti >= tSegs.length) return false;
      if (!globSegMatches(pSegs[pi], tSegs[ti])) return false;
      return matchRec(pi + 1, ti + 1);
    };
    return matchRec(0, 0);
  }
  if (pSegs.length < tSegs.length) return false;
  if (!allowDirPrefix && pSegs.length !== tSegs.length) return false;
  for (let i = 0; i < tSegs.length; i++) {
    if (!globSegMatches(pSegs[i], tSegs[i])) return false;
  }
  return true;
}

function globMatchesTarget(pat, target, allowDirPrefix = false) {
  const p = String(pat || '').replace(/[\\/]+/g, '/').replace(/^\.\//, '').replace(/\/+$/, '').toLowerCase();
  const t = String(target || '').replace(/[\\/]+/g, '/').replace(/^\.\//, '').replace(/\/+$/, '').toLowerCase();
  if (!p || !t) return false;
  if (p.startsWith('/') !== t.startsWith('/')) return false;
  const pSegs = p.split('/').filter(Boolean);
  const tSegs = t.split('/').filter(Boolean);
  return globSegPathMatches(pSegs, tSegs, allowDirPrefix);
}

function checkGlobAndSymlinkTargets(cmdStr, repoRoot) {
  const clean = stripNonExecSearchLiterals(cmdStr);
  const cleanNorm = clean.replace(/[\\/]+/g, '/');
  const gitNorm = normalizeGitCommand(clean);
  const hasWriteOrLink =
    HAS_WRITE_OR_LINK_VERB_RE.test(cleanNorm) || INTERPRETER_WRITE_RE.test(cleanNorm) || INTERPRETER_WRITE_RE.test(gitNorm);
  const base = repoRoot || resolveRepoRoot();
  let realBase = base;
  try {
    if (fs.existsSync(base)) realBase = fs.realpathSync(base);
  } catch {}
  const baseNorm = normPath(realBase);

  const candidates = [];
  for (const t of splitShellTokens(clean)) {
    if (!t.word) continue;
    const unq = unquoteShellWord(t.word).replace(/^(?:\d*(?:>>?|<<?|<&|>&))/, '').trim();
    if (!unq || /^-[A-Za-z0-9-]+$/.test(unq)) continue;
    candidates.push(unq);
    const eqIdx = unq.indexOf('=');
    if (eqIdx > 0 && eqIdx < unq.length - 1) candidates.push(unq.slice(eqIdx + 1));
    const embedded = unq.match(/(?:\/|~\/|\.\.?\/)[A-Za-z0-9._\-\/\*?\[\]]+/g);
    if (embedded) candidates.push(...embedded);
  }

  const HARD_GLOB_FILES = ['.git/config', '.git/info/attributes', '.gitconfig', '/etc/gitconfig'];
  const HARD_GLOB_DIRS = ['.git/hooks', '.git/info', '.agent-state'];
  const PROT_GLOB_FILES = ['.agents/hooks.json', 'setup-git-hooks.sh'];
  const PROT_GLOB_DIRS = ['.agents', '.agents/rules', '.agents/scripts', '.agents/skills', '.agents/config'];

  for (const rawCand of candidates) {
    let cand = rawCand.replace(/[\\/]+/g, '/');
    if (!cand || /^[a-z]+:\/\//i.test(cand)) continue;
    if (/[*?\[\]]/.test(cand)) {
      let pat = cand.toLowerCase();
      if (/^~\/(?:\.\*|\.git\*|\.gitconfig)/.test(pat)) {
        return '🛡️ BLOCKED: Glob pattern targeting ~/.gitconfig is forbidden.';
      }
      if (pat.startsWith(`${baseNorm}/`)) pat = pat.slice(baseNorm.length + 1);
      const relPat = pat.replace(/^(?:\.\.\/)+/, '');

      if (
        HARD_GLOB_FILES.some((t) => globMatchesTarget(relPat, t, false) || globMatchesTarget(pat, t, false)) ||
        HARD_GLOB_DIRS.some((t) => globMatchesTarget(relPat, t, true) || globMatchesTarget(pat, t, true)) ||
        globMatchesTarget(relPat, '.git', false)
      ) {
        return '🛡️ BLOCKED: Glob evasion targeting .git/hooks, .git/config, or .agent-state/ is forbidden.';
      }
      if (
        hasWriteOrLink &&
        (PROT_GLOB_FILES.some((t) => globMatchesTarget(relPat, t, false)) ||
          PROT_GLOB_DIRS.some((t) => globMatchesTarget(relPat, t, true)))
      ) {
        return '🛡️ BLOCKED: Glob evasion targeting protected enforcement files is forbidden.';
      }
      continue;
    }

    // Symlink check for non-glob path-like tokens
    if (!/[\\/]/.test(cand) && !cand.startsWith('.')) continue;
    let expanded = rawCand;
    if (expanded === '~') expanded = USER_HOME;
    else if (/^~[\\/]/.test(expanded)) expanded = path.join(USER_HOME, expanded.slice(2));
    if (/^[A-Za-z]:[\\/]/.test(expanded) || expanded.startsWith('\\\\')) continue;

    const rawAbs = path.resolve(realBase, expanded).replace(/[\\/]+/g, '/').toLowerCase();
    const resolved = resolvePathWithAncestors(rawCand, realBase);
    if (resolved && rawAbs && resolved !== rawAbs) {
      if (resolved.includes('.gate-secret') || resolved.includes('agy-gatekeeper/gate.key') || resolved.includes('ma-gatekeeper/gate.key')) {
        return '🛡️ BLOCKED: Symlink traversal targeting gate signing secret is forbidden.';
      }
      if (AGENT_STATE_PATH_RE.test(resolved) || HARD_GIT_CFG_RE.test(resolved)) {
        return '🛡️ BLOCKED: Symlink traversal targeting .git/ or .agent-state/ is forbidden.';
      }
      if (hasWriteOrLink && (PROTECTED_PATH_RE.test(resolved) || AGENT_CONFIG_PATH_RE.test(resolved))) {
        return '🛡️ BLOCKED: Symlink write/link targeting protected enforcement files is forbidden.';
      }
    }
  }
  return null;
}

const GIT_WRITE_SUBCMDS = new Set([
  'checkout', 'restore', 'reset', 'update-index', 'read-tree', 'checkout-index',
  'apply', 'am', 'cherry-pick', 'revert', 'merge', 'pull', 'switch', 'rm', 'mv', 'clean',
]);

function hasShellExpansion(rawTok, unqTok) {
  const r = String(rawTok || '');
  const u = String(unqTok || '');
  if (/^'[^']*'$/.test(r)) {
    // Still flag literal $ or ` in git write pathspecs/dirs as uncertain unless pure static
    return /\$|`|^~(?:[^\\/]|$)/.test(u);
  }
  return /\$|`/.test(r) || /\$|`|^~(?:[^\\/]|$)/.test(u);
}

function isRepoOrAgentsAncestorPath(rawTok, effectiveBase, repoRoot) {
  const unq = unquoteShellWord(rawTok).replace(/^(?:\d*(?:>>?|<<?|<&|>&))/, '').trim();
  if (!unq) return null;
  if (hasShellExpansion(rawTok, unq)) return 'expansion';
  const cleanTok = unq.replace(/[\\/]+/g, '/').replace(/\/+$/, '').toLowerCase();
  if (cleanTok.startsWith(':')) {
    if (cleanTok === ':/' || cleanTok === ':/*') return 'ancestor';
    if (cleanTok.startsWith(':/')) {
      return isRepoOrAgentsAncestorPath(cleanTok.slice(2), repoRoot, repoRoot) || 'ancestor';
    }
    const mm = cleanTok.match(/^:\(([^)]*)\)(.*)$/);
    if (mm) {
      const attrs = mm[1];
      const rest = mm[2];
      if (!rest || rest === '*' || /\bexclude\b/i.test(attrs)) return 'ancestor';
      const magicBase = /\btop\b/i.test(attrs) ? repoRoot : effectiveBase;
      const subHit = isRepoOrAgentsAncestorPath(rest, magicBase, repoRoot);
      if (subHit) return subHit;
      return /\b(?:glob|icase)\b/i.test(attrs) ? 'ancestor' : null;
    }
    return 'ancestor';
  }
  if (cleanTok === '.agents' || cleanTok === './.agents' || cleanTok.startsWith('.agents/') || cleanTok.startsWith('./.agents/')) {
    return 'agents';
  }
  if (cleanTok === '.' || cleanTok === './' || cleanTok === '*' || cleanTok === '..' || cleanTok === '../') {
    return 'ancestor';
  }
  if (/[\\/]/.test(unq) || unq.startsWith('.')) {
    const resolved = resolvePathWithAncestors(unq, effectiveBase || repoRoot);
    const repoNorm = normPath(repoRoot);
    const agentsNorm = normPath(path.join(repoRoot, '.agents'));
    if (resolved) {
      if (resolved === agentsNorm || resolved.startsWith(`${agentsNorm}/`)) return 'agents';
      if (resolved === repoNorm || agentsNorm.startsWith(`${resolved}/`)) return 'ancestor';
    }
  }
  return null;
}

function checkGitWriteScope(cmdStr, repoRoot, depth = 0, initBase = null, initUncertain = false) {
  const raw = String(cmdStr || '');
  if (!raw) return null;
  if (depth > MAX_SHELL_DEPTH) {
    return {
      decision: 'force_ask',
      reason: '🛡️ PROTECTED: Shell nesting depth limit exceeded during git write inspection (fail-closed).',
    };
  }
  const tokens = splitShellTokens(raw);
  let chainBase = initBase || repoRoot;
  let chainUncertain = initUncertain;
  let i = 0;
  while (i < tokens.length) {
    const seg = [];
    while (i < tokens.length) {
      if (!tokens[i].op) {
        seg.push(tokens[i].word);
        i++;
        continue;
      }
      if (seg.length && tokens[i].op === '$(') {
        i++;
        let pDepth = 1;
        const innerParts = [];
        while (i < tokens.length && pDepth > 0) {
          if (tokens[i].op === '$(' || tokens[i].op === '(') pDepth++;
          else if (tokens[i].op === ')') {
            pDepth--;
            if (pDepth === 0) { i++; break; }
          }
          innerParts.push(tokens[i].op ? tokens[i].op : tokens[i].word);
          i++;
        }
        const innerCmd = innerParts.join(' ');
        const subHit = checkGitWriteScope(innerCmd, repoRoot, depth + 1, chainBase, chainUncertain);
        if (subHit) return subHit;
        seg.push('$(SUBST)');
        continue;
      }
      if (seg.length && tokens[i].op === '`') {
        i++;
        const innerParts = [];
        while (i < tokens.length && tokens[i].op !== '`') {
          innerParts.push(tokens[i].op ? tokens[i].op : tokens[i].word);
          i++;
        }
        if (i < tokens.length && tokens[i].op === '`') i++;
        const innerCmd = innerParts.join(' ');
        const subHit = checkGitWriteScope(innerCmd, repoRoot, depth + 1, chainBase, chainUncertain);
        if (subHit) return subHit;
        seg.push('`SUBST`');
        continue;
      }
      break;
    }
    const op = i < tokens.length && tokens[i].op ? tokens[i].op : '';
    if (op) i++;
    if (!seg.length) {
      if (op === '\n') { chainBase = initBase || repoRoot; chainUncertain = initUncertain; }
      continue;
    }

    let idx = 0;
    while (idx < seg.length && /^[A-Za-z_][A-Za-z0-9_]*=/.test(unquoteShellWord(seg[idx]))) idx++;
    // Recurse into any executable $(...) or `...` embedded inside tokens (assignments, concatenated quotes, etc.),
    // skipping placeholders already checked above and single-quoted literal segments.
    for (const tok of seg) {
      if (tok === '$(SUBST)' || tok === '`SUBST`' || (!tok.includes('$(') && !tok.includes('`'))) continue;
      let ti = 0, inSQ = false, inDQ = false;
      while (ti < tok.length) {
        const ch = tok[ti];
        if (!inSQ && ch === '\\' && ti + 1 < tok.length) { ti += 2; continue; }
        if (!inSQ && !inDQ && ch === '$' && tok[ti + 1] === "'") {
          ti += 2;
          while (ti < tok.length && tok[ti] !== "'") {
            if (tok[ti] === '\\' && ti + 1 < tok.length) ti += 2;
            else ti++;
          }
          if (ti < tok.length) ti++;
          continue;
        }
        if (!inDQ && ch === "'") { inSQ = !inSQ; ti++; continue; }
        if (!inSQ && ch === '"') { inDQ = !inDQ; ti++; continue; }
        if (!inSQ && ch === '$' && tok[ti + 1] === '(') {
          let pDepth = 1, k = ti + 2;
          while (k < tok.length && pDepth > 0) {
            if (tok[k] === '\\' && k + 1 < tok.length) { k += 2; continue; }
            if (tok[k] === '$' && tok[k + 1] === "'") { k += 2; while (k < tok.length && tok[k] !== "'") { if (tok[k] === '\\' && k + 1 < tok.length) k += 2; else k++; } if (k < tok.length) k++; continue; }
            if (tok[k] === "'") { k++; while (k < tok.length && tok[k] !== "'") k++; if (k < tok.length) k++; continue; }
            if (tok[k] === '"') { k++; while (k < tok.length && tok[k] !== '"') { if (tok[k] === '\\' && k + 1 < tok.length) k++; k++; } if (k < tok.length) k++; continue; }
            if (tok[k] === '(') pDepth++;
            else if (tok[k] === ')') pDepth--;
            k++;
          }
          if (pDepth === 0) {
            const subHit = checkGitWriteScope(tok.slice(ti + 2, k - 1), repoRoot, depth + 1, chainBase, chainUncertain);
            if (subHit) return subHit;
            ti = k;
            continue;
          }
        }
        if (!inSQ && ch === '`') {
          let k = ti + 1;
          while (k < tok.length && tok[k] !== '`') {
            if (tok[k] === '\\' && k + 1 < tok.length) { k += 2; continue; }
            k++;
          }
          if (k < tok.length) {
            const subHit = checkGitWriteScope(tok.slice(ti + 1, k), repoRoot, depth + 1, chainBase, chainUncertain);
            if (subHit) return subHit;
            ti = k + 1;
            continue;
          }
        }
        ti++;
      }
    }
    if (idx >= seg.length) continue;

    const firstUnq = unquoteShellWord(seg[idx]);
    const base = firstUnq.split(/[\\/]/).pop().toLowerCase();

    if (base === 'cd' || base === 'pushd') {
      const target = seg[idx + 1] ? unquoteShellWord(seg[idx + 1]) : '';
      if (!target || target === '-' || hasShellExpansion(seg[idx + 1], target)) {
        chainUncertain = true;
      } else {
        let dir = target;
        if (dir === '~') dir = USER_HOME;
        else if (/^~[\\/]/.test(dir)) dir = path.join(USER_HOME, dir.slice(2));
        chainBase = path.resolve(chainBase, dir);
      }
      continue;
    }

    if (SHELL_WRAPPER_CMDS.has(base)) {
      for (let j = idx + 1; j < seg.length; j++) {
        const w = seg[j];
        if (w.length >= 2 && ((w.startsWith('"') && w.endsWith('"')) || (w.startsWith("'") && w.endsWith("'"))) && /\s/.test(w)) {
          const q = w[0];
          const inner = q === '"' ? w.slice(1, -1).replace(/\\"/g, '"') : w.slice(1, -1);
          const subHit = checkGitWriteScope(inner, repoRoot, depth + 1, chainBase, chainUncertain);
          if (subHit) return subHit;
        }
      }
      continue;
    }

    if (base !== 'git' && base !== 'git.exe') continue;
    let effectiveBase = chainBase;
    let workTreeBase = null;
    let gitOptUncertain = chainUncertain;
    const relocatedDirs = [];
    let j = idx + 1;
    while (j < seg.length) {
      const rawOpt = seg[j];
      const opt = unquoteShellWord(rawOpt);
      if (opt === '-C' || opt === '--work-tree' || opt === '--git-dir') {
        if (j + 1 < seg.length) {
          const valRaw = seg[j + 1];
          const valUnq = unquoteShellWord(valRaw);
          if (hasShellExpansion(valRaw, valUnq)) {
            gitOptUncertain = true;
          } else if (opt === '-C') {
            effectiveBase = path.resolve(effectiveBase, valUnq);
            relocatedDirs.push(effectiveBase);
          } else if (opt === '--work-tree') {
            workTreeBase = path.resolve(effectiveBase, valUnq);
            relocatedDirs.push(workTreeBase);
          }
          j += 2;
          continue;
        }
      }
      if (opt.startsWith('-C') && opt.length > 2) {
        const valUnq = opt.slice(2);
        if (hasShellExpansion(rawOpt, valUnq)) gitOptUncertain = true;
        else {
          effectiveBase = path.resolve(effectiveBase, valUnq);
          relocatedDirs.push(effectiveBase);
        }
        j++;
        continue;
      }
      if (opt.startsWith('--work-tree=')) {
        const valUnq = opt.slice('--work-tree='.length);
        if (hasShellExpansion(rawOpt, valUnq)) gitOptUncertain = true;
        else {
          workTreeBase = path.resolve(effectiveBase, valUnq);
          relocatedDirs.push(workTreeBase);
        }
        j++;
        continue;
      }
      if (GIT_TWO_ARG_OPTS.has(opt)) {
        j += 2;
        continue;
      }
      if (GIT_TWO_ARG_PREFIXES.some((p) => opt.startsWith(p)) || GIT_ZERO_ARG_OPTS.has(opt)) {
        j++;
        continue;
      }
      break;
    }
    if (j >= seg.length) continue;
    const gitSub = unquoteShellWord(seg[j]).toLowerCase();
    if (!GIT_WRITE_SUBCMDS.has(gitSub)) continue;

    if (gitOptUncertain) {
      return {
        decision: 'force_ask',
        reason: '🛡️ PROTECTED: git write operation uses dynamic expansion in working-tree/cd path (fail-closed).',
      };
    }

    const agentsNorm = normPath(path.join(repoRoot, '.agents'));
    for (const d of [effectiveBase, workTreeBase, ...relocatedDirs].filter(Boolean)) {
      const r = resolvePathWithAncestors(d, repoRoot);
      if (r && (r === agentsNorm || r.startsWith(`${agentsNorm}/`))) {
        return {
          decision: 'force_ask',
          reason: '🛡️ PROTECTED: git write operation targeting .agents/ via -C/--work-tree/cd requires explicit human approval.',
        };
      }
    }

    const argBase = workTreeBase || effectiveBase;
    let afterDashDash = false;
    for (let k = j + 1; k < seg.length; k++) {
      const argRaw = seg[k];
      const argUnq = unquoteShellWord(argRaw);
      if (/^--pathspec-from-file(?:=|$)/i.test(argUnq)) {
        return {
          decision: 'force_ask',
          reason: '🛡️ PROTECTED: git write operation with --pathspec-from-file requires explicit human approval.',
        };
      }
      if (argUnq === '--') {
        afterDashDash = true;
        continue;
      }
      if (!afterDashDash && argUnq.startsWith('-')) continue;
      if (isRepoOrAgentsAncestorPath(argRaw, argBase, repoRoot)) {
        return {
          decision: 'force_ask',
          reason: '🛡️ PROTECTED: git write operation targeting .agents/, magic/ancestor pathspec, or expansion requires explicit human approval.',
        };
      }
    }
  }
  return null;
}
// Any form of hook-path / config / include / alias / --no-ver* override.
// Split `-c alias.` into case-sensitive check so `-C alias.dir` is not falsely flagged.
const GIT_HOOK_OVERRIDE_CI_RE =
  /core\.hookspath|include\.path|includeif\.|--config-env\b|\bGIT_CONFIG_(COUNT|KEY_\d+|VALUE_\d+|PARAMETERS|GLOBAL|SYSTEM)\b|\bGIT_DIR\s*=|\bGIT_INDEX_FILE\s*=|\bGIT_EXEC_PATH\s*=|\bgit(?:\.exe)?[^\n;&|]*\s+config\b[^\n;&|]*(?:\balias\.|\s--edit\b|\s-e(?:\s|$))|--no-(?:verify|verif|veri|ver|ve|v)(?=\s|$|["'=)`;&|}])/i;
const GIT_HOOK_ALIAS_CS_RE = /\bgit(?:\.exe)?[^\n;&|]*\s-c(?:=|\s*)["']?alias\./;
function hasGitHookOverride(str) {
  return GIT_HOOK_OVERRIDE_CI_RE.test(str) || GIT_HOOK_ALIAS_CS_RE.test(str);
}

const GIT_EXEC_CONFIG_KEY_RE =
  /^(?:core\.(?:sshcommand|pager|editor|fsmonitor|askpass|gitproxy)|pager\..*|sequence\.editor|credential\.helper|diff\.external|difftool\..*\.cmd|mergetool\..*\.cmd|merge\..*\.driver|filter\..*\.(?:clean|smudge|process)|remote\..*\.(?:uploadpack|receivepack)|uploadpack\.packobjectshook|browser\..*\.cmd|gui\.editor|gpg\.(?:ssh\.|x509\.)?program)$/i;
const GIT_EXEC_ENV_VARS = new Set([
  'GIT_SSH_COMMAND',
  'GIT_SSH',
  'GIT_EXTERNAL_DIFF',
  'GIT_EDITOR',
  'GIT_SEQUENCE_EDITOR',
  'GIT_ASKPASS',
  'GIT_PROXY_COMMAND',
  'GIT_EXEC_PATH',
  'GIT_PAGER',
]);
const GIT_CONFIG_READ_FLAGS = new Set([
  '--get', '--get-all', '--get-regexp', '--get-urlmatch', '--list', '-l', '--get-color', '--get-colorbool',
]);

function isAllowedGitExecConfigVal(keyLower, val) {
  const v = String(val || '').trim();
  if (keyLower === 'core.pager' || keyLower.startsWith('pager.')) {
    return /^(?:cat|less|more|true|false|)$/i.test(v);
  }
  if (keyLower === 'core.fsmonitor') {
    return /^(?:false|true|0|1)$/i.test(v);
  }
  return false;
}

function checkGitExecConfigOverrides(cmdStr, depth = 0, failDepthDecision = 'deny', workBudget = { ops: 0, max: 5000 }) {
  const raw = String(cmdStr || '');
  if (!raw) return null;
  if (++workBudget.ops > workBudget.max) {
    return {
      decision: failDepthDecision,
      reason: '🛡️ BLOCKED: Shell analysis budget exceeded during git config override inspection (fail-closed).',
    };
  }
  if (depth > MAX_SHELL_DEPTH) {
    return {
      decision: failDepthDecision,
      reason: '🛡️ BLOCKED: Shell nesting depth limit exceeded during git config override inspection (fail-closed).',
    };
  }
  const tokens = splitShellTokens(raw);
  let i = 0;
  while (i < tokens.length) {
    if (++workBudget.ops > workBudget.max) {
      return {
        decision: failDepthDecision,
        reason: '🛡️ BLOCKED: Shell analysis budget exceeded during git config override inspection (fail-closed).',
      };
    }
    const seg = [];
    while (i < tokens.length) {
      if (!tokens[i].op) {
        seg.push(tokens[i].word);
        i++;
        continue;
      }
      if (tokens[i].op === '$(') {
        i++;
        let pDepth = 1;
        const innerParts = [];
        while (i < tokens.length && pDepth > 0) {
          if (tokens[i].op === '$(' || tokens[i].op === '(') pDepth++;
          else if (tokens[i].op === ')') {
            pDepth--;
            if (pDepth === 0) { i++; break; }
          }
          innerParts.push(tokens[i].op ? tokens[i].op : tokens[i].word);
          i++;
        }
        const subDeny = checkGitExecConfigOverrides(innerParts.join(' '), depth + 1, failDepthDecision, workBudget);
        if (subDeny) return subDeny;
        if (seg.length) seg.push('$(SUBST)');
        continue;
      }
      if (tokens[i].op === '`') {
        i++;
        const innerParts = [];
        while (i < tokens.length && tokens[i].op !== '`') {
          innerParts.push(tokens[i].op ? tokens[i].op : tokens[i].word);
          i++;
        }
        if (i < tokens.length && tokens[i].op === '`') i++;
        const subDeny = checkGitExecConfigOverrides(innerParts.join(' '), depth + 1, failDepthDecision, workBudget);
        if (subDeny) return subDeny;
        if (seg.length) seg.push('`SUBST`');
        continue;
      }
      break;
    }
    if (i < tokens.length && tokens[i].op) i++;
    if (!seg.length) continue;

    // Inspect any $(...) or `...` embedded inside tokens as well.
    for (const tok of seg) {
      if (++workBudget.ops > workBudget.max) {
        return {
          decision: failDepthDecision,
          reason: '🛡️ BLOCKED: Shell analysis budget exceeded during git config override inspection (fail-closed).',
        };
      }
      if (tok === '$(SUBST)' || tok === '`SUBST`' || (!tok.includes('$(') && !tok.includes('`'))) continue;
      let ti = 0, inSQ = false, inDQ = false;
      while (ti < tok.length) {
        const ch = tok[ti];
        if (!inSQ && ch === '\\' && ti + 1 < tok.length) { ti += 2; continue; }
        if (!inSQ && !inDQ && ch === '$' && tok[ti + 1] === "'") {
          ti += 2;
          while (ti < tok.length && tok[ti] !== "'") {
            if (tok[ti] === '\\' && ti + 1 < tok.length) ti += 2;
            else ti++;
          }
          if (ti < tok.length) ti++;
          continue;
        }
        if (!inDQ && ch === "'") { inSQ = !inSQ; ti++; continue; }
        if (!inSQ && ch === '"') { inDQ = !inDQ; ti++; continue; }
        if (!inSQ && ch === '$' && tok[ti + 1] === '(') {
          let pDepth = 1, k = ti + 2;
          while (k < tok.length && pDepth > 0) {
            if (tok[k] === '\\' && k + 1 < tok.length) { k += 2; continue; }
            if (tok[k] === '$' && tok[k + 1] === "'") { k += 2; while (k < tok.length && tok[k] !== "'") { if (tok[k] === '\\' && k + 1 < tok.length) k += 2; else k++; } if (k < tok.length) k++; continue; }
            if (tok[k] === "'") { k++; while (k < tok.length && tok[k] !== "'") k++; if (k < tok.length) k++; continue; }
            if (tok[k] === '"') { k++; while (k < tok.length && tok[k] !== '"') { if (tok[k] === '\\' && k + 1 < tok.length) k++; k++; } if (k < tok.length) k++; continue; }
            if (tok[k] === '(') pDepth++;
            else if (tok[k] === ')') pDepth--;
            k++;
          }
          if (pDepth === 0) {
            const subDeny = checkGitExecConfigOverrides(tok.slice(ti + 2, k - 1), depth + 1, failDepthDecision, workBudget);
            if (subDeny) return subDeny;
            ti = k;
            continue;
          }
        }
        if (!inSQ && ch === '`') {
          let k = ti + 1;
          while (k < tok.length && tok[k] !== '`') {
            if (tok[k] === '\\' && k + 1 < tok.length) { k += 2; continue; }
            k++;
          }
          if (k < tok.length) {
            const subDeny = checkGitExecConfigOverrides(tok.slice(ti + 1, k), depth + 1, failDepthDecision, workBudget);
            if (subDeny) return subDeny;
            ti = k + 1;
            continue;
          }
        }
        ti++;
      }
    }

    // Scan tokens in segment: enforce env assignments in prefix/wrapper position, recurse O(N) on
    // eval/env -S/wrappers, and catch `git` or `$G -c` at any offset after xargs/find/doas/timeout.
    const ENV_PREFIX_WRAPPERS = new Set([
      'env', 'export', 'sudo', 'doas', 'nohup', 'exec', 'command', 'builtin',
      'time', 'nice', 'stdbuf', 'ionice', 'timeout', 'xargs', 'eval',
    ]);
    let inPrefixChain = true;
    let expectTimeoutDur = false;
    for (let p = 0; p < seg.length; p++) {
      if (++workBudget.ops > workBudget.max) {
        return {
          decision: failDepthDecision,
          reason: '🛡️ BLOCKED: Shell analysis budget exceeded during git config override inspection (fail-closed).',
        };
      }
      const tokRaw = seg[p];
      const tokUnq = unquoteShellWord(tokRaw);
      const tokBase = tokUnq.split(/[\\/]/).pop().toLowerCase();
      const eq = tokUnq.indexOf('=');
      if (eq > 0 && /^[A-Za-z_][A-Za-z0-9_]*$/.test(tokUnq.slice(0, eq))) {
        if (inPrefixChain) {
          const envName = tokUnq.slice(0, eq).toUpperCase();
          const envVal = tokUnq.slice(eq + 1);
          if (GIT_EXEC_ENV_VARS.has(envName)) {
            if (!(envName === 'GIT_PAGER' && /^(?:cat|less|more|)$/i.test(envVal.trim()))) {
              return {
                decision: 'deny',
                reason: `🛡️ BLOCKED: Git command-executing environment override (${envName}) is forbidden.`,
              };
            }
          }
        }
        continue;
      }
      if (inPrefixChain) {
        if (ENV_PREFIX_WRAPPERS.has(tokBase)) {
          expectTimeoutDur = tokBase === 'timeout';
        } else if (expectTimeoutDur && !tokUnq.startsWith('-')) {
          expectTimeoutDur = false;
        } else if (!tokUnq.startsWith('-')) {
          inPrefixChain = false;
        }
      }
      if ((tokUnq === '-S' || /^-[A-Za-z]*S$/.test(tokUnq) || tokUnq === '--split-string') && p + 1 < seg.length) {
        const subDeny = checkGitExecConfigOverrides(unquoteShellWord(seg[p + 1]), depth + 1, failDepthDecision, workBudget);
        if (subDeny) return subDeny;
      } else if (tokUnq.startsWith('--split-string=')) {
        const subDeny = checkGitExecConfigOverrides(tokUnq.slice('--split-string='.length), depth + 1, failDepthDecision, workBudget);
        if (subDeny) return subDeny;
      }
      if (tokBase === 'eval' && p + 1 < seg.length) {
        const joined = seg.slice(p + 1).map((w) => unquoteShellWord(w)).join(' ');
        const subDeny = checkGitExecConfigOverrides(joined, depth + 1, failDepthDecision, workBudget);
        if (subDeny) return subDeny;
        break; // joined already covers all remaining tokens in this segment (prevents O(2^n) recursion)
      }
      if (
        tokRaw.length >= 2 &&
        ((tokRaw.startsWith('"') && tokRaw.endsWith('"')) || (tokRaw.startsWith("'") && tokRaw.endsWith("'"))) &&
        /\s/.test(tokRaw) &&
        /(?:git|GIT_|eval|env\b|sh\b|bash\b|zsh\b|dash\b|ksh\b|pwsh|powershell|cmd)/i.test(tokRaw.replace(/["'\\]/g, ''))
      ) {
        const inner = tokRaw[0] === '"' ? tokRaw.slice(1, -1).replace(/\\"/g, '"') : tokRaw.slice(1, -1);
        const subDeny = checkGitExecConfigOverrides(inner, depth + 1, failDepthDecision, workBudget);
        if (subDeny) return subDeny;
      }

      const cmdHasVarExp = !/^'[^']*'$/.test(tokRaw) && /\$|`/.test(tokRaw);
      const isPossibleGitCmd =
        tokBase === 'git' ||
        tokBase === 'git.exe' ||
        (cmdHasVarExp && p + 1 < seg.length && /^-c(?:$|[^C])/.test(unquoteShellWord(seg[p + 1])));
      if (!isPossibleGitCmd) continue;

      let j = p + 1;
      while (j < seg.length) {
        const opt = unquoteShellWord(seg[j]);
        if (opt === '-c' || (opt.startsWith('-c') && opt.length > 2)) {
          const kvRaw = opt === '-c' ? (j + 1 < seg.length ? seg[j + 1] : '') : seg[j];
          const kv = opt === '-c' ? unquoteShellWord(kvRaw) : opt.slice(2);
          const kvEq = kv.indexOf('=');
          const cfgKey = (kvEq >= 0 ? kv.slice(0, kvEq) : kv).trim();
          const cfgKeyLower = cfgKey.toLowerCase();
          const cfgVal = kvEq >= 0 ? kv.slice(kvEq + 1) : '';
          const rawKeyPart = kvRaw.includes('=') ? kvRaw.slice(0, kvRaw.indexOf('=')) : kvRaw;
          const keyHasExpansion = !/^'[^']*'$/.test(rawKeyPart) && /(?:\$|`)/.test(cfgKey);
          if (
            keyHasExpansion ||
            cfgKeyLower.startsWith('core.hookspath') ||
            cfgKeyLower.startsWith('include.path') ||
            cfgKeyLower.startsWith('includeif.') ||
            cfgKeyLower.startsWith('alias.') ||
            (GIT_EXEC_CONFIG_KEY_RE.test(cfgKeyLower) && !isAllowedGitExecConfigVal(cfgKeyLower, cfgVal))
          ) {
            return {
              decision: 'deny',
              reason: `🛡️ BLOCKED: Command-valued Git config override (-c ${cfgKey}) is forbidden.`,
            };
          }
          j += opt === '-c' ? 2 : 1;
          continue;
        }
        if (/^--(?:exec-path|upload-pack|receive-pack)(?:=|$)/i.test(opt)) {
          if (opt.includes('=') || opt.toLowerCase() !== '--exec-path') {
            return {
              decision: 'deny',
              reason: `🛡️ BLOCKED: Git executable override flag (${opt.split('=')[0]}) is forbidden.`,
            };
          }
          j++;
          continue;
        }
        if (GIT_TWO_ARG_OPTS.has(opt)) {
          j += 2;
          continue;
        }
        if (GIT_TWO_ARG_PREFIXES.some((pr) => opt.startsWith(pr)) || GIT_ZERO_ARG_OPTS.has(opt)) {
          j++;
          continue;
        }
        break;
      }

      for (let k = j + 1; k < seg.length; k++) {
        const aUnq = unquoteShellWord(seg[k]);
        if (/^ext::/i.test(aUnq)) {
          return {
            decision: 'deny',
            reason: '🛡️ BLOCKED: Git ext:: remote helper execution is forbidden.',
          };
        }
        if (/^--(?:upload-pack|receive-pack|exec-path)(?:=|$)/i.test(aUnq)) {
          return {
            decision: 'deny',
            reason: `🛡️ BLOCKED: Git executable override flag (${aUnq.split('=')[0]}) is forbidden.`,
          };
        }
      }

      if (j < seg.length && unquoteShellWord(seg[j]).toLowerCase() === 'config') {
        let isReadOnly = false;
        const pos = [];
        for (let k = j + 1; k < seg.length; k++) {
          const aUnq = unquoteShellWord(seg[k]);
          if (aUnq === '--') {
            for (let m = k + 1; m < seg.length; m++) pos.push(unquoteShellWord(seg[m]));
            break;
          }
          if (GIT_CONFIG_READ_FLAGS.has(aUnq.toLowerCase())) {
            isReadOnly = true;
            continue;
          }
          if (aUnq === '-f' || aUnq === '--file' || aUnq === '--blob' || aUnq === '-C') {
            k++;
            continue;
          }
          if (aUnq.startsWith('-')) continue;
          pos.push(aUnq);
        }
        if (!isReadOnly && pos.length >= 2) {
          const cfgKeyLower = pos[0].toLowerCase();
          const cfgVal = pos[1];
          if (
            /(?:\$|`)/.test(pos[0]) ||
            cfgKeyLower.startsWith('core.hookspath') ||
            cfgKeyLower.startsWith('include.path') ||
            cfgKeyLower.startsWith('includeif.') ||
            cfgKeyLower.startsWith('alias.') ||
            (GIT_EXEC_CONFIG_KEY_RE.test(cfgKeyLower) && !isAllowedGitExecConfigVal(cfgKeyLower, cfgVal))
          ) {
            return {
              decision: 'deny',
              reason: `🛡️ BLOCKED: Modifying command-valued Git config (${pos[0]}) is forbidden.`,
            };
          }
        }
      }
    }
  }
  return null;
}

// Interpreter-based file writes (node/python/perl/ruby/awk/dd/PowerShell .NET) — these
// bypass shell redirect detection, so they are treated as writes (parity with protect-enforcement.sh,
// which never allowlists interpreters for .agent-state/).
const INTERPRETER_WRITE_RE =
  /(\b(write|append)FileSync\b|\b(write|append)File\s*\(|\bwriteSync\b|\bopenSync\b|\bftruncate|\btruncate\b|\brenameSync\b|\bunlinkSync\b|\brmSync\b|\bcopyFileSync\b|\bcpSync\b|\bsymlinkSync\b|\bcreateWriteStream\b|\bfs\.promises\b|\bopen\s*\([^)]*['"][wax+]|\bos\.open\b|\.write_text\b|\.write_bytes\b|\bshutil\.|\bos\.(remove|rename|replace|unlink|symlink)\b|\bperl\b|\bruby\b|\bawk\b|\bdd\b|\binstall\s|\bln\s|\bgit\s+(checkout|restore|reset|update-index|read-tree|checkout-index|apply|am|cherry-pick|revert|merge|pull|switch)\b|\[System\.IO\.File\]|\bWriteAllText\b|\bAdd-Content\b|\bNew-Item\b.*-Value)/i;

// Cross-Model review fingerprint — byte-identical to codex-lib.sh codex_staged_fingerprint()
// (git diff --cached --no-color --no-ext-diff -- . <CODEX_EXCLUDES> | sha256sum).
const CODEX_EXCLUDES = [
  ':(exclude).agent-state',
  ':(exclude).agent-reports',
  ':(exclude).last-staging-deploy',
  ':(exclude)*.md',
  ':(exclude)platform-docs',
];
function gitRawBuffer(repoRoot, args) {
  const wsUnix = repoRoot.replace(/\\/g, '/');
  return execFileSync(
    'git',
    ['-c', 'core.fsmonitor=false', '-c', `safe.directory=${wsUnix}`, '-C', repoRoot, ...args],
    { maxBuffer: 64 * 1024 * 1024, timeout: 8000, windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'] }
  );
}
function checkCrossModelReview(repoRoot, stateDir) {
  let files;
  let diff;
  try {
    files = gitRawBuffer(repoRoot, ['diff', '--cached', '--name-only', '--', '.', ...CODEX_EXCLUDES])
      .toString('utf8')
      .trim();
    if (!files) return null; // no reviewable code staged
    diff = gitRawBuffer(repoRoot, ['diff', '--cached', '--no-color', '--no-ext-diff', '--', '.', ...CODEX_EXCLUDES]);
  } catch {
    return 'Cross-Model review cannot be evaluated (git diff failed) — fail-closed';
  }
  const fp = crypto.createHash('sha256').update(diff).digest('hex');
  const f = path.join(stateDir, 'codex-review.json');
  if (!fs.existsSync(f)) return 'Cross-Model review missing (run: bash .agents/scripts/run-codex-review-gate.sh)';
  let cr;
  try {
    cr = readJsonNoBom(f);
  } catch {
    return 'Cross-Model review state unreadable (re-run run-codex-review-gate.sh)';
  }
  const st = cr.status || 'PENDING';
  if ((cr.staged_fingerprint || '') !== fp) {
    return 'Cross-Model review is STALE (staged diff changed after review — re-run run-codex-review-gate.sh)';
  }
  if (st === 'SKIPPED_RATE_LIMIT' || st === 'UNAVAILABLE') {
    return `External CLI cascade ${st} — complete the internal fallback review (run-codex-review-gate.sh --fallback)`;
  }
  if (st !== 'PASS' && st !== 'PASS_FALLBACK') {
    return `Cross-Model review status is ${st} (${cr.blocking_count ?? '?'} CRITICAL/HIGH/OWASP unresolved — see ${cr.report || '.agent-reports/codex/review-latest.md'})`;
  }
  return null;
}
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
      ['-c', 'core.fsmonitor=false', '-c', `safe.directory=${wsUnix}`, '-C', repoRoot, ...args],
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
function checkSingleRunCommand(cmd, repoRoot) {
  const cmdNorm = String(cmd || '').replace(/[\\/]+/g, '/');
  const cmdPathNorm = normPath(cmd);
  const cmdClean = stripNonExecSearchLiterals(cmd);
  const cmdCleanNorm = cmdClean.replace(/[\\/]+/g, '/');
  const cmdCleanPathNorm = normPath(cmdClean);
  const gitNorm = normalizeGitCommand(cmdClean);
  const hasWriteOrLink =
    HAS_WRITE_OR_LINK_VERB_RE.test(cmdCleanNorm) ||
    INTERPRETER_WRITE_RE.test(cmdCleanNorm) ||
    INTERPRETER_WRITE_RE.test(gitNorm);

  // 1. Hard-deny checks FIRST (before any force_ask)
  if (
    (HARD_GIT_CFG_RE.test(cmdPathNorm) ||
      HARD_GIT_CFG_RE.test(cmdCleanPathNorm) ||
      /\bcd\s+[^\n;&|]*\.git(\/|\s|;|$|&)/i.test(cmdCleanPathNorm)) &&
    hasWriteOrLink
  ) {
    return {
      decision: 'deny',
      reason: '🛡️ BLOCKED: Modifying .git/hooks, .git/config, or ~/.gitconfig is forbidden.',
    };
  }

  const globSymErr = checkGlobAndSymlinkTargets(cmd, repoRoot);
  if (globSymErr) {
    return { decision: 'deny', reason: globSymErr };
  }

  if (AGENT_STATE_PATH_RE.test(cmdCleanPathNorm)) {
    const noChaining = !/[;&`\n]|\$\(/.test(cmdNorm);
    const isOfficialRunner =
      noChaining &&
      /run-(qa|security|regression|vault|docs|skills|codex-review)-gate\.sh|write-security-review\.sh|sync-security-from-review\.sh/.test(
        cmdNorm
      ) &&
      !/(>|>>|\btee\b|\bcp\b|\bmv\b|\brm\b|sed\s+-i)/i.test(cmdNorm) &&
      !INTERPRETER_WRITE_RE.test(cmdNorm) &&
      !/sign-gate\.sh/.test(cmdNorm);
    const isAllowedMeta =
      (noChaining && /mkdir\s+-p.*\.agent-state|New-Item.*\.agent-state|git\s+add\s+.*\.agent-state\//.test(gitNorm)) ||
      (noChaining &&
        /(\bcat\b|\bjq\b|\bhead\b|\btail\b|\bwc\b|\bgrep\b|\bGet-Content\b|python3? -c.*import json.*load).*\.agent-state\//i.test(cmdNorm) &&
        !/(>|>>|\btee\b|\bcp\b|\bmv\b|\brm\b|sed\s+-i|\bSet-Content\b|\bOut-File\b)/i.test(cmdNorm) &&
        !INTERPRETER_WRITE_RE.test(cmdNorm));
    if (!isOfficialRunner && !isAllowedMeta) {
      return {
        decision: 'deny',
        reason:
          '🛡️ BLOCKED: Direct access to .agent-state/ is restricted. Use the official gate scripts (run-*-gate.sh) instead.',
      };
    }
  }

  if (/sign-gate\.sh/i.test(cmdCleanNorm)) {
    return {
      decision: 'deny',
      reason: '🛡️ BLOCKED: Direct invocation of sign-gate.sh is forbidden. Run run-*-gate.sh instead.',
    };
  }

  if (
    /\/api\/gatekeeper\/(sign|register)/i.test(cmdCleanNorm) ||
    (/18099/.test(cmdCleanNorm) && /\bPOST\b|-X\s*POST|--data|--json|--form|-F\s|-d\s|-d@|-d["']|-Method\s+Post|-Body\b|\.UploadString|\.PostAsync/i.test(cmdCleanNorm))
  ) {
    return {
      decision: 'deny',
      reason: '🛡️ BLOCKED: Direct HTTP POSTs to :18099 / /api/gatekeeper/sign are forbidden.',
    };
  }

  if (/systemctl\s+(stop|disable|mask|kill|edit)\s+.*(ma|agy)-gatekeeper|Stop-(Service|ScheduledTask).*AntigravityGatekeeper|pkill.*gatekeeper/i.test(cmdCleanNorm)) {
    return { decision: 'deny', reason: '🛡️ BLOCKED: Stopping or disabling gatekeeper service is forbidden.' };
  }

  if (/gate\.sec|\.git\/hooks\/\.|\.git\/hooks\/\*|\/etc\/(ma|agy)-gatekeeper\/gate\.key|ProgramData\/agy-gatekeeper\/gate\.key/i.test(cmdCleanNorm)) {
    return { decision: 'deny', reason: '🛡️ BLOCKED: Access to gate signing secret is forbidden.' };
  }

  if (/\bgit\s+add\s+((-A|--all|\.)(\s|$))/.test(gitNorm)) {
    return {
      decision: 'deny',
      reason: '🛡️ BLOCKED: git add -A / git add . / git add --all is forbidden. Stage explicit file paths.',
    };
  }

  if (/\bgit\s+stash\b/.test(gitNorm)) {
    return { decision: 'deny', reason: '🛡️ BLOCKED: git stash is forbidden.' };
  }

  const cmdForGitFlags = stripCommitMessageArgs(cmdCleanNorm);
  const gitForFlags = stripCommitMessageArgs(gitNorm);
  const execCfgRes = checkGitExecConfigOverrides(stripCommitMessageArgs(cmdClean), 0, 'force_ask');
  if (execCfgRes && execCfgRes.decision === 'deny') return execCfgRes;
  if (/\bgit\b/i.test(cmdCleanNorm) && (hasGitHookOverride(cmdForGitFlags) || hasGitHookOverride(gitForFlags))) {
    return {
      decision: 'deny',
      reason: '🛡️ BLOCKED: Bypassing git hooks (--no-verify / --no-ver* / core.hooksPath / include.path / alias.* / GIT_CONFIG_* / --config-env) is forbidden.',
    };
  }
  if (/\bGIT_CONFIG_(COUNT|KEY_\d+|VALUE_\d+|PARAMETERS|GLOBAL|SYSTEM)\b|\bGIT_DIR\s*=|\bGIT_INDEX_FILE\s*=|\bGIT_EXEC_PATH\s*=/i.test(cmdCleanNorm)) {
    return { decision: 'deny', reason: '🛡️ BLOCKED: Git hook/config override via environment is forbidden.' };
  }
  if (/\bgit\s+commit\b(.*)/i.test(gitForFlags)) {
    const rest = gitForFlags.match(/\bgit\s+commit\b(.*)/i)[1];
    // -n anywhere in a short-flag cluster (e.g. -n, -nm, -an, "-n") == --no-verify
    if (/(^|\s)["']?-[a-z0-9]*n[a-z0-9]*["']?(\s|$|[)`"';&|}])/i.test(rest)) {
      return { decision: 'deny', reason: '🛡️ BLOCKED: git commit -n (no-verify) is forbidden.' };
    }
  }

  if (/(codex|claude|opencode)-orchestrate\.sh/.test(cmdCleanNorm) && /--force-write/.test(cmdCleanNorm)) {
    return { decision: 'deny', reason: '🛡️ BLOCKED: --force-write is forbidden in this Single-Writer workspace.' };
  }

  if (/(^|[;&|]\s*)([^\s/]*\/)?codex(\s|$)/.test(cmdCleanNorm)) {
    const isMeta = /\bcodex\s+(--help|-h|--version|-V|login|logout|status|models)(\s|$)/.test(cmdCleanNorm) && !/\b(exec|apply|resume|cloud)\b/.test(cmdCleanNorm);
    const isRo = /\bexec\b/.test(cmdCleanNorm) && /(-s|--sandbox)[\s=]+"?read-only"?/.test(cmdCleanNorm) && !/workspace-write|danger-full-access|dangerously-bypass|--full-auto/.test(cmdCleanNorm);
    if (!isMeta && !isRo) {
      return { decision: 'deny', reason: '🛡️ BLOCKED: Codex may ONLY run with explicit -s read-only here.' };
    }
  }

  if (/(^|[;&|]\s*)([^\s/]*\/)?claude(\s|$)/.test(cmdCleanNorm)) {
    const isMeta = /\bclaude\s+(login|logout|auth|status|update|upgrade|--help|-h|--version|-v|-V)(\s|$)/.test(cmdCleanNorm) && !/\s(-p|--print)\b/.test(cmdCleanNorm);
    const isPlan = /permission-mode[\s=]+"?plan"?/.test(cmdCleanNorm) && !/acceptEdits|bypassPermissions|dontAsk|dangerously-skip-permissions/.test(cmdCleanNorm);
    if (!isMeta && !isPlan) {
      return { decision: 'deny', reason: '🛡️ BLOCKED: Claude CLI may ONLY run with --permission-mode plan here.' };
    }
  }

  if (/(^|[;&|]\s*)([^\s/]*\/)?opencode(\s|$)/.test(cmdCleanNorm)) {
    const isMeta = /(--help|-h|--version|-v|-V|\bmodels(\s|$))/.test(cmdCleanNorm);
    const isRo = /\brun\b/.test(cmdCleanNorm) && /readonly-auditor/.test(cmdCleanNorm) && !/--auto/.test(cmdCleanNorm);
    if (!isMeta && !isRo) {
      return { decision: 'deny', reason: '🛡️ BLOCKED: OpenCode CLI must run with --agent readonly-auditor here.' };
    }
  }

  // 2. force_ask AFTER all deny checks
  if (
    (PROTECTED_PATH_RE.test(cmdCleanPathNorm) ||
      AGENT_CONFIG_PATH_RE.test(cmdCleanPathNorm) ||
      /\bcd\s+["']?\.agents\b/i.test(cmdCleanNorm)) &&
    hasWriteOrLink
  ) {
    return {
      decision: 'force_ask',
      reason: '🛡️ PROTECTED: Command targets enforcement control plane file. Requires explicit human approval.',
    };
  }
  const gitScopeRes = checkGitWriteScope(cmdClean, repoRoot);
  if (gitScopeRes) return gitScopeRes;
  if (execCfgRes) return execCfgRes;

  return { decision: 'allow' };
}

function handleProtectEnforcement(input) {
  const toolName = input?.toolCall?.name || '';
  const args = input?.toolCall?.args || {};
  const repoRoot = resolveRepoRoot();
  const matchesProtected = (str) => PROTECTED_PATH_RE.test(normPath(str));

  // Fail-closed tool classification: any tool that is not a known read-only tool and carries a
  // path-like argument is treated as a WRITE tool (covers multi_replace_file_content, future tools…).
  const READ_ONLY_TOOLS = new Set(['read_file', 'view_file', 'list_dir', 'grep_search', 'find_by_name', 'search_web', 'read_url_content', 'view_file_outline', 'view_code_item']);
  const pathArg = args.Path || args.TargetFile || args.AbsolutePath || args.FilePath || args.file_path || args.path || '';
  const isWriteTool =
    ['write_file', 'edit_file', 'write_to_file', 'replace_file_content', 'multi_replace_file_content'].includes(toolName) ||
    (toolName !== 'run_command' && !READ_ONLY_TOOLS.has(toolName) && !!pathArg);

  if (isWriteTool) {
    const targetCandidates = Array.from(new Set([normPath(pathArg), resolvePathWithAncestors(pathArg, repoRoot)].filter(Boolean)));
    // Hard-deny checks FIRST before force_ask
    for (const tf of targetCandidates) {
      if (AGENT_STATE_PATH_RE.test(tf) || AGENT_CONFIG_PATH_RE.test(tf) || tf.includes('.agent-state/') || tf.includes('.agents/config/')) {
        return out({
          decision: 'deny',
          reason: '🛡️ BLOCKED: Direct write to .agent-state/ or .agents/config/ is forbidden.',
        });
      }
      if (HARD_GIT_CFG_RE.test(tf)) {
        return out({
          decision: 'deny',
          reason: '🛡️ BLOCKED: Direct modification of git hooks or git config (.git/hooks, .git/config, ~/.gitconfig) is forbidden.',
        });
      }
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
    if (targetCandidates.some((tf) => matchesProtected(tf))) {
      return out({
        decision: 'force_ask',
        reason:
          '🛡️ PROTECTED: This file is part of the enforcement control plane (.agents/hooks.json, rules/, scripts/, skills/). Modifying it requires explicit human approval.',
      });
    }
  }

  if (toolName === 'read_file' || toolName === 'view_file') {
    const rawRead = String(args.Path || args.AbsolutePath || '');
    const readCandidates = Array.from(new Set([normPath(rawRead), resolvePathWithAncestors(rawRead, repoRoot)].filter(Boolean)));
    if (readCandidates.some((t) => t.includes('.gate-secret') || t.includes('agy-gatekeeper/gate.key') || t.includes('ma-gatekeeper/gate.key'))) {
      return out({ decision: 'deny', reason: '🛡️ BLOCKED: Reading gate signing secret is forbidden.' });
    }
  }

  if (toolName === 'run_command') {
    const cmd = String(args.CommandLine || '');
    const canon = canonicalShell(cmd);
    const r1 = checkSingleRunCommand(cmd, repoRoot);
    if (r1.decision === 'deny') return out(r1);
    const r2 = canon && canon !== cmd ? checkSingleRunCommand(canon, repoRoot) : { decision: 'allow' };
    if (r2.decision === 'deny') return out(r2);
    if (r1.decision === 'force_ask') return out(r1);
    if (r2.decision === 'force_ask') return out(r2);
  }

  return out({ decision: 'allow' });
}

// -----------------------------------------------------------------------------
// 2. commit-gate
// -----------------------------------------------------------------------------
async function handleCommitGate(input) {
  const repoRoot = resolveRepoRoot();
  const stateDir = path.join(repoRoot, '.agent-state');
  const rawCmdLine = IS_GIT_HOOK ? 'git commit' : String(input?.toolCall?.args?.CommandLine || '');
  const canonCmd = IS_GIT_HOOK ? 'git commit' : canonicalShell(rawCmdLine);
  const rawClean = IS_GIT_HOOK ? 'git commit' : stripNonExecSearchLiterals(rawCmdLine);
  const canonClean = IS_GIT_HOOK ? 'git commit' : stripNonExecSearchLiterals(canonCmd);
  const cmdLine = IS_GIT_HOOK ? 'git commit' : normalizeGitCommand(canonClean);

  if (!IS_GIT_HOOK) {
    const rawFlags = stripCommitMessageArgs(rawClean);
    const canonFlags = stripCommitMessageArgs(canonClean);
    const normFlags = stripCommitMessageArgs(cmdLine);
    const execCfgDeny = checkGitExecConfigOverrides(rawFlags) || checkGitExecConfigOverrides(canonFlags);
    if (execCfgDeny) return out(execCfgDeny);
    if (
      (/\bgit\b/i.test(canonClean) || /\bgit\b/i.test(cmdLine)) &&
      (hasGitHookOverride(rawFlags) || hasGitHookOverride(canonFlags) || hasGitHookOverride(normFlags))
    ) {
      return out({
        decision: 'deny',
        reason: '⛔ BLOCKED: Git hook/alias/config override (--no-ver* / core.hooksPath / include.path / alias.* / GIT_CONFIG_* / --config-env) is forbidden.',
      });
    }
  }

  if (!IS_GIT_HOOK && !/\bgit\s+(commit|push)\b/i.test(cmdLine)) {
    return out({ decision: 'allow' });
  }

  const errors = [];
  const isCommit = /\bgit\s+commit\b/i.test(cmdLine);
  const isPush = /\bgit\s+push\b/i.test(cmdLine);

  if (isCommit && !IS_GIT_HOOK) {
    const cmdLineNoMsg = stripCommitMessageArgs(cmdLine);
    if (/git\s+commit\b.*(\s|^)["']?(-[a-z0-9]*[noai][a-z0-9]*|--no-(?:verify|verif|veri|ver|ve|v)|--all|--only|--include)["']?(?=\s|$|=|[)`"';&|}])/i.test(cmdLineNoMsg)) {
      errors.push('git commit flags --no-verify/--no-ver*/-n/-a/-o/-i/--all/--only/--include are forbidden');
    }
    const restMatch = cmdLine.match(/git\s+commit\b(.*)/i);
    if (restMatch) {
      const tokens = restMatch[1].trim().match(/(?:[^\s"');&|}]+|"[^"]*"|'[^']*')+/g) || [];
      const valOpts = new Set([
        '-m', '-F', '-c', '-C', '--message', '--file', '--reedit-message',
        '--reuse-message', '--fixup', '--squash', '--author', '--date', '-u', '--untracked-files',
      ]);
      for (let i = 0; i < tokens.length; i++) {
        const t = tokens[i].replace(/^["']|["']$/g, '');
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
    let stagedAll = null;
    try {
      stagedAll = gitRawBuffer(repoRoot, ['diff', '--cached', '--name-only']).toString('utf8').split(/\r?\n/).filter(Boolean);
    } catch {
      errors.push('Cannot list staged files (git failed) — fail-closed');
    }
    stagedAll = stagedAll || [];
    const hasNonState = stagedAll.some((f) => !f.replace(/\\/g, '/').startsWith('.agent-state/'));
    const hasState = stagedAll.some((f) => f.replace(/\\/g, '/').startsWith('.agent-state/'));
    if (hasNonState && !hasState) {
      errors.push('No .agent-state/ gate files staged');
    }
    const crErr = checkCrossModelReview(repoRoot, stateDir);
    if (crErr) errors.push(crErr);
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
  if (MODE === 'canonical-shell') {
    process.stdout.write(canonicalShell(readStdinUtf8()));
    return;
  }
  if (MODE === 'check-git-override') {
    const raw = readStdinUtf8();
    const rawFlags = stripCommitMessageArgs(stripNonExecSearchLiterals(raw));
    const canonFlags = stripCommitMessageArgs(stripNonExecSearchLiterals(canonicalShell(raw)));
    const deny = checkGitExecConfigOverrides(rawFlags) || checkGitExecConfigOverrides(canonFlags);
    return out(deny || { decision: 'allow' });
  }
  if (MODE === 'normalize-git') {
    // Helper for commit-gate.sh: stdin = raw command line, stdout = git-global-option-normalized line.
    process.stdout.write(normalizeGitCommand(stripNonExecSearchLiterals(canonicalShell(readStdinUtf8()))));
    return;
  }
  let input = {};
  if (!IS_GIT_HOOK && MODE !== 'preflight') {
    const raw = readStdinUtf8().trim();
    if (!raw && (MODE === 'commit-gate' || MODE === 'protect-enforcement')) {
      // Fail-closed: a PreToolUse hook always receives a JSON payload.
      return out({ decision: 'deny', reason: '⛔ BLOCKED: Empty PreToolUse hook input (fail-closed)' });
    }
    if (raw) {
      try {
        input = JSON.parse(raw.replace(/^\uFEFF/, ''));
      } catch {
        if (MODE === 'commit-gate' || MODE === 'protect-enforcement') {
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
