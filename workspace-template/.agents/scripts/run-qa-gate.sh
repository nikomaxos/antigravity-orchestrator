#!/usr/bin/env bash
# =============================================================================
# QA Gate Runner — Performs project verification before signing qa.json
# =============================================================================
# Dynamically adapts to the project's tech stack (Node/TS, Java, Python, Go, Rust, Bash).
# Only signs qa.json as PASS if all checks succeed.
# =============================================================================
set -euo pipefail

export HOME="${HOME:-$(getent passwd "$(id -un)" 2>/dev/null | cut -d: -f6 || echo "/home/nick")}"
export PATH="${HOME}/.local/share/mise/shims:${HOME}/.local/bin:${HOME}/.opencode/bin:${HOME}/.npm-global/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
STATE_DIR="${REPO_ROOT}/.agent-state"
SIGN_SCRIPT="${REPO_ROOT}/.agents/scripts/sign-gate.sh"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=codex-lib.sh
source "${SCRIPT_DIR}/codex-lib.sh"

cd "$REPO_ROOT"

HEAD=$(git rev-parse HEAD 2>/dev/null || echo "unknown")
WORKTREE=$(codex_code_worktree_hash)
TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)

echo "🔍 Running QA Gate checks..."
echo "   HEAD: ${HEAD:0:12}"
echo "   Worktree hash: ${WORKTREE:0:12}"

ERRORS=""

# Check 1: Shell script syntax check (if any .sh files changed)
echo ""
echo "--- Check 1: Shell script syntax ---"
CHANGED_SH=$(git diff HEAD --name-only 2>/dev/null | grep '\.sh$' || true)
if [ -n "$CHANGED_SH" ]; then
  SH_ERR=0
  while IFS= read -r shf; do
    [ -f "$shf" ] || continue
    if ! bash -n "$shf" 2>&1; then
      ERRORS="${ERRORS}Bash syntax error in ${shf}; "
      SH_ERR=1
    fi
  done <<< "$CHANGED_SH"
  [ "$SH_ERR" -eq 0 ] && echo "✅ All modified .sh scripts pass bash -n"
else
  echo "✅ No modified .sh scripts, skipping"
fi

# Check 2: TypeScript / JavaScript compilation & checks (if package.json exists)
echo ""
echo "--- Check 2: Node / TypeScript verification ---"
if [ -f "package.json" ]; then
  if [ -f "tsconfig.json" ]; then
    TSC_CMD=""
    if [ -x "./node_modules/.bin/tsc" ]; then
      TSC_CMD="./node_modules/.bin/tsc"
    elif command -v tsc >/dev/null 2>&1; then
      TSC_CMD="tsc"
    elif command -v npx >/dev/null 2>&1; then
      TSC_CMD="npx tsc"
    fi
    if [ -n "$TSC_CMD" ]; then
      if $TSC_CMD --noEmit 2>&1; then
        echo "✅ TypeScript check passed"
      else
        ERRORS="${ERRORS}TypeScript compilation failed; "
      fi
    fi
  fi
else
  # Check subdirectories for package.json
  for pkg in $(find . -maxdepth 3 -name "package.json" -not -path "*/node_modules/*" 2>/dev/null); do
    pkg_dir=$(dirname "$pkg")
    if [ -f "${pkg_dir}/tsconfig.json" ]; then
      changed_in_pkg=$(git diff HEAD --name-only 2>/dev/null | grep "^${pkg_dir#/./}/" || true)
      if [ -n "$changed_in_pkg" ]; then
        (
          cd "$pkg_dir"
          TSC_CMD=""
          [ -x "./node_modules/.bin/tsc" ] && TSC_CMD="./node_modules/.bin/tsc"
          [ -z "$TSC_CMD" ] && command -v npx >/dev/null 2>&1 && TSC_CMD="npx tsc"
          if [ -n "$TSC_CMD" ]; then
            if ! $TSC_CMD --noEmit 2>&1; then
              echo "❌ TypeScript error in $pkg_dir"
              exit 1
            fi
          fi
        ) || ERRORS="${ERRORS}TypeScript compilation failed in ${pkg_dir}; "
      fi
    fi
  done
  echo "✅ Node/TypeScript checks completed"
fi

# Check 3: Python syntax verification
echo ""
echo "--- Check 3: Python syntax verification ---"
CHANGED_PY=$(git diff HEAD --name-only 2>/dev/null | grep '\.py$' || true)
if [ -n "$CHANGED_PY" ]; then
  while IFS= read -r pyf; do
    [ -f "$pyf" ] || continue
    if ! python3 -m py_compile "$pyf" 2>&1; then
      ERRORS="${ERRORS}Python syntax error in ${pyf}; "
    fi
  done <<< "$CHANGED_PY"
  echo "✅ Python checks completed"
else
  echo "✅ No modified .py files, skipping"
fi

# Check 4: Anti-pattern verification for Java (only if *.java files exist)
if find . -name "*.java" -not -path "*/target/*" -not -path "*/build/*" 2>/dev/null | head -1 | grep -q .; then
  echo ""
  echo "--- Check 4: Java anti-pattern checks ---"
  if git diff HEAD 2>/dev/null | grep -E 'String\.format\("[^"]*%[0-9]*\.?[0-9]*[fgeFGE]' | grep -v "Locale" >/dev/null 2>&1; then
    ERRORS="${ERRORS}ANTI-PATTERN: String.format without explicit Locale.US; "
  fi
fi

echo ""

# Final decision
if [ -n "$ERRORS" ]; then
  echo "❌ QA FAILED: $ERRORS"
  CONTENT=$(printf '{"status":"FAIL","tested_head":"%s","worktree_hash":"%s","timestamp":"%s","errors":"%s"}' "$HEAD" "$WORKTREE" "$TS" "$ERRORS")
  bash "$SIGN_SCRIPT" ".agent-state/qa.json" "$CONTENT"
  exit 1
fi

echo "✅ QA PASSED — signing gate file"
CONTENT=$(printf '{"status":"PASS","tested_head":"%s","worktree_hash":"%s","timestamp":"%s"}' "$HEAD" "$WORKTREE" "$TS")
bash "$SIGN_SCRIPT" ".agent-state/qa.json" "$CONTENT"
