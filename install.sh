#!/usr/bin/env bash
# =============================================================================
# Antigravity Multi-Model Orchestrator & Gatekeeper Installer (`install.sh`)
# =============================================================================
# Installs global Antigravity configurations, skills, CLIs, helper binaries,
# and optionally the root-owned `agy-gatekeeper.service`.
#
# Usage:
#   ./install.sh [--with-gatekeeper] [--skip-clis]
# =============================================================================
set -euo pipefail

export HOME="${HOME:-$(getent passwd "$(id -un)" 2>/dev/null | cut -d: -f6 || echo "/home/nick")}"
export PATH="${HOME}/.local/bin:${HOME}/.opencode/bin:${HOME}/.npm-global/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

WITH_GATEKEEPER=0
SKIP_CLIS=0

for arg in "$@"; do
  case "$arg" in
    --with-gatekeeper) WITH_GATEKEEPER=1 ;;
    --skip-clis) SKIP_CLIS=1 ;;
    -h|--help)
      cat <<'EOF'
Usage:
  ./install.sh [OPTIONS]

Options:
  --with-gatekeeper  Also install and start the root-owned agy-gatekeeper.service (requires sudo)
  --skip-clis        Skip automatic CLI installation (Codex, Claude, OpenCode)
  -h, --help         Show this help message
EOF
      exit 0
      ;;
  esac
done

echo "🚀 Installing Antigravity Multi-Model Orchestrator for user: $(id -un) (HOME=${HOME})"

# 1. Global Antigravity Config & Rules
echo ""
echo "📝 1. Installing global rules into ~/.gemini/config/..."
mkdir -p "${HOME}/.gemini/config"
cp -f "${SCRIPT_DIR}/global/gemini/config/AGENTS.md" "${HOME}/.gemini/config/AGENTS.md"
cp -f "${SCRIPT_DIR}/global/gemini/config/GEMINI.md" "${HOME}/.gemini/config/GEMINI.md"
cp -f "${SCRIPT_DIR}/global/gemini/config/GEMINI.md" "${HOME}/.gemini/GEMINI.md" 2>/dev/null || true
echo "   ✓ ~/.gemini/config/AGENTS.md"
echo "   ✓ ~/.gemini/config/GEMINI.md"

# 2. Global Skills
echo ""
echo "🧠 2. Installing global skills into ~/.gemini/config/skills/..."
mkdir -p "${HOME}/.gemini/config/skills"
for skill in claude codex opencode multi-model-delegation codex-review; do
  mkdir -p "${HOME}/.gemini/config/skills/${skill}"
  cp -r "${SCRIPT_DIR}/global/gemini/config/skills/${skill}/"* "${HOME}/.gemini/config/skills/${skill}/"
  chmod +x "${HOME}/.gemini/config/skills/${skill}"/scripts/*.sh 2>/dev/null || true
  echo "   ✓ Installed skill: ${skill}"
done

# 3. Global OpenCode Configuration
echo ""
echo "⚙️ 3. Configuring OpenCode..."
mkdir -p "${HOME}/.config/opencode"
if [ ! -f "${HOME}/.config/opencode/opencode.json" ]; then
  cp "${SCRIPT_DIR}/global/opencode/opencode.json" "${HOME}/.config/opencode/opencode.json"
  echo "   ✓ Created ~/.config/opencode/opencode.json"
else
  echo "   ℹ️ Preserved existing ~/.config/opencode/opencode.json"
fi

# 4. Install Helper Binaries into ~/.local/bin/
echo ""
echo "🔧 4. Installing CLI binaries into ~/.local/bin/..."
mkdir -p "${HOME}/.local/bin"
cp -f "${SCRIPT_DIR}/bin/agy-init-workspace" "${HOME}/.local/bin/agy-init-workspace"
cp -f "${SCRIPT_DIR}/bin/agy-arch-sync" "${HOME}/.local/bin/agy-arch-sync"
cp -f "${SCRIPT_DIR}/bin/frontier-orchestrate" "${HOME}/.local/bin/frontier-orchestrate"
cp -f "${SCRIPT_DIR}/bin/agy-setup-clis" "${HOME}/.local/bin/agy-setup-clis"
chmod +x "${HOME}/.local/bin/agy-init-workspace" \
         "${HOME}/.local/bin/agy-arch-sync" \
         "${HOME}/.local/bin/frontier-orchestrate" \
         "${HOME}/.local/bin/agy-setup-clis"
echo "   ✓ ~/.local/bin/agy-init-workspace"
echo "   ✓ ~/.local/bin/agy-arch-sync"
echo "   ✓ ~/.local/bin/frontier-orchestrate"
echo "   ✓ ~/.local/bin/agy-setup-clis"

# Ensure PATH in shell startup
for rc in "${HOME}/.bashrc" "${HOME}/.zshrc"; do
  if [ -f "$rc" ]; then
    if ! grep -q '\.local/bin' "$rc" 2>/dev/null; then
      echo 'export PATH="${HOME}/.local/bin:${HOME}/.opencode/bin:${HOME}/.npm-global/bin:${PATH}"' >> "$rc"
    fi
  fi
done

# 5. External CLIs setup
if [ "$SKIP_CLIS" -eq 0 ]; then
  echo ""
  echo "🤖 5. Verifying external frontier CLIs..."
  bash "${SCRIPT_DIR}/bin/agy-setup-clis" --install
fi

# 6. Optional Gatekeeper Installation
if [ "$WITH_GATEKEEPER" -eq 1 ]; then
  echo ""
  echo "🛡️ 6. Installing agy-gatekeeper.service via sudo..."
  sudo bash "${SCRIPT_DIR}/gatekeeper/install-gatekeeper.sh"
else
  echo ""
  echo "ℹ️  Gatekeeper Service:"
  if curl -sf "http://127.0.0.1:18099/api/gatekeeper/health" >/dev/null 2>&1; then
    echo "   ✓ A gatekeeper daemon is already listening on 127.0.0.1:18099."
  else
    echo "   To install the root gatekeeper service on this machine, run:"
    echo "   sudo ${SCRIPT_DIR}/gatekeeper/install-gatekeeper.sh"
  fi
fi

echo ""
echo "🎉 Installation complete!"
echo ""
echo "Next steps:"
echo "  1. Initialize any project with full hard gates:"
echo "     agy-init-workspace /path/to/my-project"
echo "  2. Authenticate external models (Pools B, C, D):"
echo "     agy-setup-clis --auth"
echo "  3. Smoke test all 4 pools:"
echo "     agy-setup-clis --test"
echo "  4. Sync architecture updates across machines:"
echo "     agy-arch-sync"
