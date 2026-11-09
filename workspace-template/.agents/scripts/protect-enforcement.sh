#!/usr/bin/env bash
# =============================================================================
# Protected Control Plane — blocks agent from modifying enforcement files
# without explicit human approval.
# =============================================================================
set -euo pipefail

INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.toolCall.name // ""')

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
      return 0
    fi
  done
  return 1
}

# Check write_to_file and replace_file_content
if [ "$TOOL_NAME" = "write_to_file" ] || [ "$TOOL_NAME" = "replace_file_content" ]; then
  TARGET_FILE=$(echo "$INPUT" | jq -r '.toolCall.args.TargetFile // .toolCall.args.Path // ""')
  if check_path "$TARGET_FILE"; then
    echo '{"decision": "force_ask", "reason": "🛡️ PROTECTED: This file is part of the enforcement control plane (.agents/hooks.json, rules/, scripts/, skills/). Modifying it requires explicit human approval."}'
    exit 0
  fi
fi

# Check run_command for shell writes to protected paths
if [ "$TOOL_NAME" = "run_command" ]; then
  CMD=$(echo "$INPUT" | jq -r '.toolCall.args.CommandLine // ""')
  for pattern in "${PROTECTED_PATTERNS[@]}"; do
    if echo "$CMD" | grep -qE "(>|>>|rm |mv |cp |sed -i|chmod |tee ).*(${pattern})"; then
      echo '{"decision": "force_ask", "reason": "🛡️ PROTECTED: Command targets enforcement control plane file. Requires explicit human approval."}'
      exit 0
    fi
  done

  # Block direct writes to .agent-state/ gate files (must use gate scripts)
  if echo "$CMD" | grep -qE '\.agent-state/'; then
    if echo "$CMD" | grep -qE 'run-(qa|security|regression|vault|docs|skills|codex-review)-gate\.sh|write-security-review\.sh|sync-security-from-review\.sh' && \
       ! echo "$CMD" | grep -qE '(^|[;&|][[:space:]]*|\$\(|`)(env[[:space:]]+|timeout[[:space:]]+[^[:space:]]+[[:space:]]+|nohup[[:space:]]+|bash[[:space:]]+|sh[[:space:]]+|source[[:space:]]+|\.[[:space:]]+|exec[[:space:]]+)*([^[:space:]]*/)?["'\'']*sign-gate\.sh'; then
      : # allowed
    elif echo "$CMD" | grep -qE 'mkdir -p.*\.agent-state'; then
      : # allowed
    elif echo "$CMD" | grep -qE 'git[[:space:]]+add[[:space:]]+.*\.agent-state/'; then
      : # allowed
    elif echo "$CMD" | grep -qE '(cat|jq|head|tail|wc|grep|python3? -c.*import json.*load).*\.agent-state/' && \
         ! echo "$CMD" | grep -qE '(>|>>|tee |cp |mv |rm |sed -i)'; then
      : # allowed
    else
      echo '{"decision": "deny", "reason": "🛡️ BLOCKED: Direct access to .agent-state/ is restricted. Use the gate scripts (./scripts/run-*-gate.sh) instead."}'
      exit 0
    fi
  fi

  # Block direct execution of sign-gate.sh
  if echo "$CMD" | grep -qE '(^|[;&|][[:space:]]*|\$\(|`)(env[[:space:]]+|timeout[[:space:]]+[^[:space:]]+[[:space:]]+|nohup[[:space:]]+|bash[[:space:]]+|sh[[:space:]]+|source[[:space:]]+|\.[[:space:]]+|exec[[:space:]]+)*([^[:space:]]*/)?["'\'']*sign-gate\.sh([[:space:]"'\'']|$)'; then
    echo '{"decision": "deny", "reason": "🛡️ BLOCKED: Direct invocation of sign-gate.sh is forbidden. Run the official gate runner scripts (run-*-gate.sh) instead."}'
    exit 0
  fi

  # Block direct agent calls to /api/gatekeeper/sign or POSTs to :18099
  if echo "$CMD" | grep -qiE '/api/gatekeeper/sign|18099.*(-X[[:space:]]*POST|--request[[:space:]]*POST|--data|-d[[:space:]])|(-X[[:space:]]*POST|--request[[:space:]]*POST|--data|-d[[:space:]]).*18099'; then
    echo '{"decision": "deny", "reason": "🛡️ BLOCKED: Direct calls to /api/gatekeeper/sign are forbidden. Use the official gate runner scripts (run-*-gate.sh) instead."}'
    exit 0
  fi

  # Block any attempt to read/modify gatekeeper files or stop/disable service
  if echo "$CMD" | grep -qiE 'systemctl[[:space:]]+(stop|disable|mask|kill|edit)[[:space:]]+.*(agy|ma)-gatekeeper|pkill.*gatekeeper|killall.*gatekeeper'; then
    echo '{"decision": "deny", "reason": "🛡️ BLOCKED: Stopping or disabling gatekeeper service is forbidden."}'
    exit 0
  fi
  if echo "$CMD" | grep -qE '(/etc/(agy|ma)-gatekeeper|/usr/local/lib/(agy|ma)-gatekeeper|/var/lib/(agy|ma)-gatekeeper)'; then
    if echo "$CMD" | grep -qE '^[[:space:]]*(stat|ls)[[:space:]]' && \
       ! echo "$CMD" | grep -qE '(>|>>|rm |mv |cp |sed |chmod |chown |tee |cat |head |tail |less |more |grep |jq |openssl )'; then
      : # allowed
    else
      echo '{"decision": "deny", "reason": "🛡️ BLOCKED: Direct reading or modifying gatekeeper root paths is forbidden."}'
      exit 0
    fi
  fi

  # Block bulk git add that bypasses path inspection
  if echo "$CMD" | grep -qE 'git[[:space:]]+add[[:space:]]+((-A|--all|\.)[[:space:]]|(-A|--all|\.)$)'; then
    echo '{"decision": "deny", "reason": "🛡️ BLOCKED: git add -A / git add . / git add --all is forbidden. Use explicit file paths so the protection layer can inspect them."}'
    exit 0
  fi

  # Block git stash
  if echo "$CMD" | grep -qE 'git[[:space:]]+stash'; then
    echo '{"decision": "deny", "reason": "🛡️ BLOCKED: git stash is forbidden — could be used to bypass gate file protections."}'
    exit 0
  fi

  # Block read of HMAC secret
  if echo "$CMD" | grep -qiE 'gate.sec|\.git/hooks/\.|\.git/hooks/\*'; then
    echo '{"decision": "deny", "reason": "🛡️ BLOCKED: Access to gate signing secret is forbidden."}'
    exit 0
  fi

  # External CLIs must run READ-ONLY (Single-Writer invariant)
  if echo "$CMD" | grep -qE '(^|[;&|][[:space:]]*|(timeout[[:space:]]+[^[:space:]]+[[:space:]]+))([^[:space:]]*/)?codex([[:space:]]|$)'; then
    if echo "$CMD" | grep -qE '(--help|-h|--version|-V|[[:space:]](login|logout|status|models)([[:space:]]|$))'; then
      : # allowed
    elif echo "$CMD" | grep -qE '[[:space:]]exec([[:space:]]|$)' && \
         echo "$CMD" | grep -qE '(-s|--sandbox)[[:space:]=]+"?read-only"?' && \
         ! echo "$CMD" | grep -qE 'workspace-write|danger-full-access|dangerously-bypass|--full-auto|--approve-for-me|codex[[:space:]]+(apply|a)([[:space:]]|$)'; then
      : # allowed
    else
      echo '{"decision": "deny", "reason": "🛡️ BLOCKED: Codex may ONLY run with explicit -s read-only here. Antigravity is the single writer."}'
      exit 0
    fi
  fi

  if echo "$CMD" | grep -qE '(^|[;&|][[:space:]]*|(timeout[[:space:]]+[^[:space:]]+[[:space:]]+))([^[:space:]]*/)?claude([[:space:]]|$)'; then
    if echo "$CMD" | grep -qE '(--help|-h|--version|-v|-V|[[:space:]](login|logout|auth|status)([[:space:]]|$))'; then
      : # allowed
    elif echo "$CMD" | grep -qE 'permission-mode[[:space:]=]+"?plan"?' && \
         ! echo "$CMD" | grep -qE 'permission-mode[[:space:]=]+"?(acceptEdits|auto|bypassPermissions|dontAsk)"?|dangerously-skip-permissions' && \
         ! echo "$CMD" | grep -qE 'allowedTools.*(Write|Edit|MultiEdit|NotebookEdit)'; then
      : # allowed
    else
      echo '{"decision": "deny", "reason": "🛡️ BLOCKED: Claude CLI may ONLY run with --permission-mode plan (read-only) in this workspace. Antigravity is the single writer."}'
      exit 0
    fi
  fi

  if echo "$CMD" | grep -qE '(^|[;&|][[:space:]]*|(timeout[[:space:]]+[^[:space:]]+[[:space:]]+))([^[:space:]]*/)?opencode([[:space:]]|$)'; then
    if echo "$CMD" | grep -qE -- '(--help|-h|--version|-v|-V|[[:space:]]models([[:space:]]|$))'; then
      : # allowed
    elif echo "$CMD" | grep -qE '[[:space:]]run([[:space:]]|$)' && \
         echo "$CMD" | grep -qE 'readonly-auditor' && \
         ! echo "$CMD" | grep -qE -- '--auto'; then
      : # allowed
    else
      echo '{"decision": "deny", "reason": "🛡️ BLOCKED: OpenCode CLI must run with --agent readonly-auditor in this workspace. Antigravity is the single writer."}'
      exit 0
    fi
  fi
fi

# Block view_file of HMAC secret
if [ "$TOOL_NAME" = "view_file" ] || [ "$TOOL_NAME" = "read_file" ]; then
  TARGET=$(echo "$INPUT" | jq -r '.toolCall.args.AbsolutePath // .toolCall.args.Path // ""')
  if echo "$TARGET" | grep -q '.gate-secret'; then
    echo '{"decision": "deny", "reason": "🛡️ BLOCKED: Reading gate signing secret is forbidden."}'
    exit 0
  fi
fi

# Block direct write_to_file targeting .agent-state/
if [ "$TOOL_NAME" = "write_to_file" ] || [ "$TOOL_NAME" = "replace_file_content" ] || [ "$TOOL_NAME" = "edit_file" ]; then
  TARGET_FILE=$(echo "$INPUT" | jq -r '.toolCall.args.TargetFile // .toolCall.args.Path // ""')
  if echo "$TARGET_FILE" | grep -q '\.agent-state/'; then
    echo '{"decision": "deny", "reason": "🛡️ BLOCKED: Direct write to .agent-state/ is forbidden. Use the gate scripts instead."}'
    exit 0
  fi
fi

# Anti-pattern checks (Scoped to Java if present)
if [ "$TOOL_NAME" = "write_to_file" ] || [ "$TOOL_NAME" = "replace_file_content" ] || [ "$TOOL_NAME" = "edit_file" ]; then
  TARGET_FILE=$(echo "$INPUT" | jq -r '.toolCall.args.TargetFile // .toolCall.args.Path // ""')
  if [[ "$TARGET_FILE" == *.java ]]; then
    CONTENT=$(echo "$INPUT" | jq -r '.toolCall.args.CodeContent // .toolCall.args.ReplacementContent // .toolCall.args.Content // .toolCall.args.Replacement // ""')
    if echo "$CONTENT" | grep -qE 'String\.format\("[^"]*%[0-9]*\.?[0-9]*[fgeFGE]' && ! echo "$CONTENT" | grep -q "Locale"; then
      echo '{"decision": "deny", "reason": "🛡️ ANTI-PATTERN DETECTED: String.format used without explicit Locale. Always use String.format(Locale.US, ...)."}'
      exit 0
    fi
  fi
fi

echo '{"decision": "allow"}'
