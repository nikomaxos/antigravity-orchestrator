#!/usr/bin/env bash
set -euo pipefail

# Protected Control Plane — blocks agent from modifying enforcement files
# without explicit human approval.

INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.toolCall.name // ""')

# Protected paths (relative to repo root)
PROTECTED_PATTERNS=(
  ".agents/hooks.json"
  ".agents/rules/"
  ".agents/scripts/"
  ".agents/skills/"
  "setup-git-hooks.sh"
)

check_path() {
  local path="$1"
  for pattern in "${PROTECTED_PATTERNS[@]}"; do
    if echo "$path" | grep -q "$pattern"; then
      return 0  # matched
    fi
  done
  return 1  # not matched
}

# Check write_to_file and replace_file_content
if [ "$TOOL_NAME" = "write_to_file" ] || [ "$TOOL_NAME" = "replace_file_content" ]; then
  TARGET_FILE=$(echo "$INPUT" | jq -r '.toolCall.args.TargetFile // ""')
  if check_path "$TARGET_FILE"; then
    echo '{"decision": "force_ask", "reason": "🛡️ PROTECTED: This file is part of the enforcement control plane (.agents/hooks.json, rules/, scripts/, skills/). Modifying it requires explicit human approval."}'
    exit 0
  fi
fi

# Check run_command for shell writes to protected paths
if [ "$TOOL_NAME" = "run_command" ]; then
  CMD=$(echo "$INPUT" | jq -r '.toolCall.args.CommandLine // ""')
  for pattern in "${PROTECTED_PATTERNS[@]}"; do
    # Check for redirects (>, >>), rm, mv, cp, sed -i, chmod targeting protected files
    if echo "$CMD" | grep -qE "(>|>>|rm |mv |cp |sed -i|chmod |tee ).*(${pattern})"; then
      echo '{"decision": "force_ask", "reason": "🛡️ PROTECTED: Command targets enforcement control plane file. Requires explicit human approval."}'
      exit 0
    fi
  done

  # Block direct writes to .agent-state/ gate files (must use gate scripts)
  # Covers: redirects, tee, cp, mv, sed, printf/echo redirects,
  # AND alternative tools: dd, python, perl, ruby, awk, node
  if echo "$CMD" | grep -qE '\.agent-state/'; then
    # Allow ONLY the official gate runner scripts (and never when chained with sign-gate.sh)
    if echo "$CMD" | grep -qE 'run-(qa|security|regression|vault|docs|skills|codex-review)-gate\.sh|write-security-review\.sh|sync-security-from-review\.sh' && \
       ! echo "$CMD" | grep -qE '(^|[;&|][[:space:]]*|\$\(|`)(env[[:space:]]+|timeout[[:space:]]+[^[:space:]]+[[:space:]]+|nohup[[:space:]]+|bash[[:space:]]+|sh[[:space:]]+|source[[:space:]]+|\.[[:space:]]+|exec[[:space:]]+)*([^[:space:]]*/)?["'\'']*sign-gate\.sh'; then
      : # allowed — gate script invocation
    elif echo "$CMD" | grep -qE 'mkdir -p.*\.agent-state'; then
      : # allowed — directory creation
    elif echo "$CMD" | grep -qE 'git[[:space:]]+add[[:space:]]+.*\.agent-state/'; then
      : # allowed — staging gate files for commit
    elif echo "$CMD" | grep -qE '(cat|jq|head|tail|wc|grep|python3? -c.*import json.*load).*\.agent-state/' && \
         ! echo "$CMD" | grep -qE '(>|>>|tee |cp |mv |rm |sed -i)'; then
      : # allowed — reading gate files (not writing)
    else
      echo '{"decision": "deny", "reason": "🛡️ BLOCKED: Direct access to .agent-state/ is restricted. Use the gate scripts (./scripts/run-*-gate.sh) instead."}'
      exit 0
    fi
  fi

  # Block direct execution of sign-gate.sh (even when chained after run-*-gate.sh or prefixed with timeout/env/nohup/bash/source)
  if echo "$CMD" | grep -qE '(^|[;&|][[:space:]]*|\$\(|`)(env[[:space:]]+|timeout[[:space:]]+[^[:space:]]+[[:space:]]+|nohup[[:space:]]+|bash[[:space:]]+|sh[[:space:]]+|source[[:space:]]+|\.[[:space:]]+|exec[[:space:]]+)*([^[:space:]]*/)?["'\'']*sign-gate\.sh([[:space:]"'\'']|$)'; then
    echo '{"decision": "deny", "reason": "🛡️ BLOCKED: Direct invocation of sign-gate.sh is forbidden. Run the official gate runner scripts (run-*-gate.sh) instead."}'
    exit 0
  fi

  # Block direct agent calls to /api/gatekeeper/sign or POSTs to :18099 (must go through official run-*-gate.sh scripts)
  if echo "$CMD" | grep -qiE '/api/gatekeeper/sign|18099.*(-X[[:space:]]*POST|--request[[:space:]]*POST|--data|-d[[:space:]])|(-X[[:space:]]*POST|--request[[:space:]]*POST|--data|-d[[:space:]]).*18099'; then
    echo '{"decision": "deny", "reason": "🛡️ BLOCKED: Direct calls to /api/gatekeeper/sign are forbidden. Use the official gate runner scripts (run-*-gate.sh) instead."}'
    exit 0
  fi

  # Block any attempt to read/modify /etc/ma-gatekeeper, /usr/local/lib/ma-gatekeeper, /var/lib/ma-gatekeeper,
  # or stop/disable/mask/kill ma-gatekeeper.service
  if echo "$CMD" | grep -qiE 'systemctl[[:space:]]+(stop|disable|mask|kill|edit)[[:space:]]+.*ma-gatekeeper|pkill.*ma-gatekeeper|killall.*ma-gatekeeper'; then
    echo '{"decision": "deny", "reason": "🛡️ BLOCKED: Stopping or disabling ma-gatekeeper.service is forbidden."}'
    exit 0
  fi
  if echo "$CMD" | grep -qE '(/etc/ma-gatekeeper|/usr/local/lib/ma-gatekeeper|/var/lib/ma-gatekeeper)'; then
    if echo "$CMD" | grep -qE '^[[:space:]]*(stat|ls)[[:space:]]' && \
       ! echo "$CMD" | grep -qE '(>|>>|rm |mv |cp |sed |chmod |chown |tee |cat |head |tail |less |more |grep |jq |openssl )'; then
      : # allowed — read-only metadata stat/ls check
    else
      echo '{"decision": "deny", "reason": "🛡️ BLOCKED: Reading or modifying /etc/ma-gatekeeper, /usr/local/lib/ma-gatekeeper, or /var/lib/ma-gatekeeper is forbidden."}'
      exit 0
    fi
  fi

  # Block bulk git add that bypasses .agent-state path inspection
  # The agent must use explicit file paths so each path can be checked.
  if echo "$CMD" | grep -qE 'git[[:space:]]+add[[:space:]]+((-A|--all|\.)[[:space:]]|(-A|--all|\.)$)'; then
    echo '{"decision": "deny", "reason": "🛡️ BLOCKED: git add -A / git add . / git add --all is forbidden. Use explicit file paths so the protection layer can inspect them."}'
    exit 0
  fi

  # Block git stash (can be used to hide/restore .agent-state files)
  if echo "$CMD" | grep -qE 'git[[:space:]]+stash'; then
    echo '{"decision": "deny", "reason": "🛡️ BLOCKED: git stash is forbidden — could be used to bypass gate file protections."}'
    exit 0
  fi

  # Block read of HMAC secret — covers wildcards, partial names, hex encoding
  if echo "$CMD" | grep -qiE 'gate.sec|\.git/hooks/\.|\.git/hooks/\*'; then
    echo '{"decision": "deny", "reason": "🛡️ BLOCKED: Access to gate signing secret is forbidden."}'
    exit 0
  fi

  # Codex review gate must run with the canonical environment. Overriding the
  # binary/HOME/PATH/model could fake "UNAVAILABLE" and unlock the fallback path.
  if echo "$CMD" | grep -qE 'run-codex-review-gate\.sh' && \
     echo "$CMD" | grep -qE '(CODEX_[A-Z_]+|CLAUDE_[A-Z_]+|OPENCODE_[A-Z_]+|MODEL_ROUTING_FILE|HOME|PATH|CODEX_HOME)=|env[[:space:]]+-|unset[[:space:]]'; then
    echo '{"decision": "deny", "reason": "🛡️ BLOCKED: run-codex-review-gate.sh must be invoked without environment overrides."}'
    exit 0
  fi

  # External CLIs (Codex, Claude Code, OpenCode) are READ-ONLY analysts in this workspace (Single-Writer positive allowlists).
  if echo "$CMD" | grep -qE '(^|[;&|][[:space:]]*|(timeout[[:space:]]+[^[:space:]]+[[:space:]]+))([^[:space:]]*/)?codex([[:space:]]|$)'; then
    if echo "$CMD" | grep -qE '(^|[;&|][[:space:]]*)([^[:space:]]*/)?codex[[:space:]]+(--help|-h|--version|-V|login|logout|status|models)([[:space:]]|$)' && \
       ! echo "$CMD" | grep -qE '[[:space:]](exec|apply|a|resume|cloud)([[:space:]]|$)|dangerously-bypass|workspace-write|danger-full-access|--full-auto'; then
      : # allowed — explicit metadata/auth command, without exec chaining
    elif echo "$CMD" | grep -qE '[[:space:]]exec([[:space:]]|$)' && \
         echo "$CMD" | grep -qE '(-s|--sandbox)[[:space:]=]+"?read-only"?' && \
         ! echo "$CMD" | grep -qE 'workspace-write|danger-full-access|dangerously-bypass|--full-auto|--approve-for-me|codex[[:space:]]+(apply|a)([[:space:]]|$)'; then
      : # allowed — explicit read-only sandbox
    else
      echo '{"decision": "deny", "reason": "🛡️ BLOCKED: Codex may ONLY run with explicit -s read-only here (use .agents/scripts/codex-rca.sh, run-codex-review-gate.sh, or codex-orchestrate.sh). Antigravity is the single writer."}'
      exit 0
    fi
  fi

  if echo "$CMD" | grep -qE '(^|[;&|][[:space:]]*|(timeout[[:space:]]+[^[:space:]]+[[:space:]]+))([^[:space:]]*/)?claude([[:space:]]|$)'; then
    if echo "$CMD" | grep -qE '(^|[;&|][[:space:]]*)([^[:space:]]*/)?claude[[:space:]]+(login|logout|auth|status|update|upgrade|--help|-h|--version|-v|-V)([[:space:]]|$)' && \
       ! echo "$CMD" | grep -qE -- '(-p|--print)([[:space:]]|$)' && \
       ! echo "$CMD" | grep -qE 'dangerously-skip-permissions|permission-mode[[:space:]=]+"?(acceptEdits|auto|bypassPermissions|dontAsk)"?|allowedTools.*(Write|Edit|MultiEdit|NotebookEdit)'; then
      : # allowed — explicit metadata/auth/update command, not a prompt session or write mode
    elif echo "$CMD" | grep -qE 'permission-mode[[:space:]=]+"?plan"?' && \
         ! echo "$CMD" | grep -qE 'permission-mode[[:space:]=]+"?(acceptEdits|auto|bypassPermissions|dontAsk)"?|dangerously-skip-permissions' && \
         ! echo "$CMD" | grep -qE 'allowedTools.*(Write|Edit|MultiEdit|NotebookEdit)'; then
      : # allowed — explicit plan (read-only) mode without write tools
    else
      echo '{"decision": "deny", "reason": "🛡️ BLOCKED: Claude CLI may ONLY run with --permission-mode plan (read-only) in this workspace. Antigravity is the single writer."}'
      exit 0
    fi
  fi

  if echo "$CMD" | grep -qE '(^|[;&|][[:space:]]*|(timeout[[:space:]]+[^[:space:]]+[[:space:]]+))([^[:space:]]*/)?opencode([[:space:]]|$)'; then
    if echo "$CMD" | grep -qE -- '(--help|-h|--version|-v|-V|[[:space:]]models([[:space:]]|$))'; then
      : # allowed — metadata command
    elif echo "$CMD" | grep -qE '[[:space:]]run([[:space:]]|$)' && \
         echo "$CMD" | grep -qE 'readonly-auditor' && \
         ! echo "$CMD" | grep -qE -- '--auto'; then
      : # allowed — explicit readonly-auditor agent
    else
      echo '{"decision": "deny", "reason": "🛡️ BLOCKED: OpenCode CLI must run with --agent readonly-auditor in this workspace. Antigravity is the single writer."}'
      exit 0
    fi
  fi

  if echo "$CMD" | grep -qE '(codex|claude|opencode)-orchestrate\.sh'; then
    if echo "$CMD" | grep -qE -- '--force-write'; then
      echo '{"decision": "deny", "reason": "🛡️ BLOCKED: --force-write is forbidden in this Single-Writer workspace."}'
      exit 0
    fi
    if echo "$CMD" | grep -qE -- '(-C|--cd|--workdir)[[:space:]=]+' && \
       ! echo "$CMD" | grep -qE -- '(-C|--cd|--workdir)[[:space:]=]+"?(/home/nick/Development/messaging-agent/?|\.)"?([[:space:]]|$)'; then
      echo '{"decision": "deny", "reason": "🛡️ BLOCKED: Orchestrator wrappers invoked from this workspace must target /home/nick/Development/messaging-agent so Single-Writer read-only protection stays active."}'
      exit 0
    fi
  fi
fi

# Block view_file of HMAC secret
if [ "$TOOL_NAME" = "view_file" ]; then
  TARGET=$(echo "$INPUT" | jq -r '.toolCall.args.AbsolutePath // ""')
  if echo "$TARGET" | grep -q '.gate-secret'; then
    echo '{"decision": "deny", "reason": "🛡️ BLOCKED: Reading gate signing secret is forbidden."}'
    exit 0
  fi
fi

# Block write_to_file targeting .agent-state/ or .agents/config/
if [ "$TOOL_NAME" = "write_to_file" ] || [ "$TOOL_NAME" = "replace_file_content" ]; then
  TARGET_FILE=$(echo "$INPUT" | jq -r '.toolCall.args.TargetFile // ""')
  if echo "$TARGET_FILE" | grep -qE '(\.agent-state/|\.agents/config/)'; then
    echo '{"decision": "deny", "reason": "🛡️ BLOCKED: Direct write to .agent-state/ or .agents/config/ is forbidden."}'
    exit 0
  fi
fi

# --- ANTI-PATTERN GATE (Applies to all subagents and tools) ---
# Block writes containing known bad patterns
if [ "$TOOL_NAME" = "write_to_file" ] || [ "$TOOL_NAME" = "replace_file_content" ]; then
  CONTENT=$(echo "$INPUT" | jq -r '.toolCall.args.CodeContent // .toolCall.args.ReplacementContent // ""')
  
  # 1. Locale-dependent String.format
  if echo "$CONTENT" | grep -qE 'String\.format\("[^"]*%[0-9]*\.?[0-9]*[fgeFGE]' && ! echo "$CONTENT" | grep -q "Locale"; then
    echo '{"decision": "deny", "reason": "🛡️ ANTI-PATTERN DETECTED: String.format used without explicit Locale. This causes bugs in environments with non-US default locales. Always use String.format(Locale.US, ...)."}'
    exit 0
  fi
  
  # 2. java.sql.Timestamp in native queries
  if echo "$CONTENT" | grep -q "nativeQuery" && echo "$CONTENT" | grep -q "java.sql.Timestamp"; then
    echo '{"decision": "deny", "reason": "🛡️ ANTI-PATTERN DETECTED: java.sql.Timestamp used near nativeQuery. This causes severe timezone discrepancies. Always use java.time.Instant and EXTRACT(EPOCH FROM ...) in the query."}'
    exit 0
  fi
fi

echo '{"decision": "allow"}'
