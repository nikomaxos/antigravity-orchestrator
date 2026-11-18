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
export PATH="${HOME}/.local/share/mise/shims:${HOME}/.local/bin:${HOME}/.opencode/bin:${HOME}/.npm-global/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH}"

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
if [ -f "${SCRIPT_DIR}/global/gemini/config/model-routing.json" ]; then
  cp -f "${SCRIPT_DIR}/global/gemini/config/model-routing.json" "${HOME}/.gemini/config/model-routing.json"
  echo "   ✓ ~/.gemini/config/model-routing.json"
fi
echo "   ✓ ~/.gemini/config/AGENTS.md"
echo "   ✓ ~/.gemini/config/GEMINI.md"

# Configure Turbo CitC Zero-Popup Access
if [ -f "${SCRIPT_DIR}/scripts/configure-antigravity-turbo.sh" ]; then
  bash "${SCRIPT_DIR}/scripts/configure-antigravity-turbo.sh"
fi

# 2. Global Skills & Workflows
echo ""
echo "🧠 2. Installing global skills & workflows into ~/.gemini/config/..."
mkdir -p "${HOME}/.gemini/config/skills"
for skill_dir in "${SCRIPT_DIR}/global/gemini/config/skills"/*; do
  if [ -d "$skill_dir" ]; then
    skill=$(basename "$skill_dir")
    mkdir -p "${HOME}/.gemini/config/skills/${skill}"
    cp -r "${skill_dir}/"* "${HOME}/.gemini/config/skills/${skill}/"
    chmod +x "${HOME}/.gemini/config/skills/${skill}"/scripts/*.sh 2>/dev/null || true
    echo "   ✓ Installed skill: ${skill}"
  fi
done

if [ -d "${SCRIPT_DIR}/global/gemini/config/workflows" ]; then
  mkdir -p "${HOME}/.gemini/config/workflows" "${HOME}/.gemini/config/global_workflows"
  cp -r "${SCRIPT_DIR}/global/gemini/config/workflows/"* "${HOME}/.gemini/config/workflows/"
  cp -r "${SCRIPT_DIR}/global/gemini/config/workflows/"* "${HOME}/.gemini/config/global_workflows/"
  echo "   ✓ Installed global workflows"
fi

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
cp -f "${SCRIPT_DIR}/bin/agy-init-workspace.ps1" "${HOME}/.local/bin/agy-init-workspace.ps1" 2>/dev/null || true
cp -f "${SCRIPT_DIR}/bin/agy-arch-sync" "${HOME}/.local/bin/agy-arch-sync"
cp -f "${SCRIPT_DIR}/bin/agy-arch-sync.ps1" "${HOME}/.local/bin/agy-arch-sync.ps1" 2>/dev/null || true
cp -f "${SCRIPT_DIR}/bin/frontier-orchestrate" "${HOME}/.local/bin/frontier-orchestrate"
cp -f "${SCRIPT_DIR}/bin/frontier-orchestrate.ps1" "${HOME}/.local/bin/frontier-orchestrate.ps1" 2>/dev/null || true
cp -f "${SCRIPT_DIR}/bin/agy-setup-clis" "${HOME}/.local/bin/agy-setup-clis"
cp -f "${SCRIPT_DIR}/bin/architecture-sync" "${HOME}/.local/bin/architecture-sync"
cp -f "${SCRIPT_DIR}/bin/architecture-sync.ps1" "${HOME}/.local/bin/architecture-sync.ps1" 2>/dev/null || true
cp -f "${SCRIPT_DIR}/bin/architecture-sync.cmd" "${HOME}/.local/bin/architecture-sync.cmd" 2>/dev/null || true
cp -f "${SCRIPT_DIR}/bin/architecture-push" "${HOME}/.local/bin/architecture-push" 2>/dev/null || true
chmod +x "${HOME}/.local/bin/agy-init-workspace" \
         "${HOME}/.local/bin/agy-arch-sync" \
         "${HOME}/.local/bin/frontier-orchestrate" \
         "${HOME}/.local/bin/agy-setup-clis" \
         "${HOME}/.local/bin/architecture-sync" \
         "${HOME}/.local/bin/architecture-push" 2>/dev/null || true
echo "   ✓ ~/.local/bin/agy-init-workspace"
echo "   ✓ ~/.local/bin/agy-init-workspace.ps1"
echo "   ✓ ~/.local/bin/agy-arch-sync"
echo "   ✓ ~/.local/bin/agy-arch-sync.ps1"
echo "   ✓ ~/.local/bin/frontier-orchestrate"
echo "   ✓ ~/.local/bin/frontier-orchestrate.ps1"
echo "   ✓ ~/.local/bin/agy-setup-clis"
echo "   ✓ ~/.local/bin/architecture-sync"
echo "   ✓ ~/.local/bin/architecture-sync.ps1"
echo "   ✓ ~/.local/bin/architecture-push"

# 4b. Install Fleet Push Daemon & MCP Server into ~/.local/lib/agy-fleet/
FLEET_LIB="${HOME}/.local/lib/agy-fleet"
mkdir -p "$FLEET_LIB"
if [ -d "${SCRIPT_DIR}/fleet" ]; then
  cp -f "${SCRIPT_DIR}/fleet/"* "$FLEET_LIB/" 2>/dev/null || true
  chmod +x "${FLEET_LIB}/"*.js 2>/dev/null || true
  echo "   ✓ ~/.local/lib/agy-fleet/ (agy-sync-daemon.js, agy-fleet-mcp.js, agy-fleet-hub.js)"
fi

# Resolve Node binary path cleanly across mise (Omarchy/Arch) and distro paths
NODE_BIN=""
for cand in "${HOME}/.local/share/mise/shims/node" "$(command -v node 2>/dev/null || true)" "/usr/bin/node" "/usr/local/bin/node"; do
  if [ -n "$cand" ] && [ -x "$cand" ]; then
    NODE_BIN="$cand"
    break
  fi
done

# Register agy-fleet Stdio MCP server in ~/.gemini/config/mcp_config.json
MCP_CFG="${HOME}/.gemini/config/mcp_config.json"
MCP_SCRIPT="${FLEET_LIB}/agy-fleet-mcp.js"
if [ -n "$NODE_BIN" ] && [ -f "$MCP_SCRIPT" ]; then
  "$NODE_BIN" -e '
const fs = require("fs");
const [cfgPath, nodeBin, mcpScript] = process.argv.slice(1);
let data = { mcpServers: {} };
try {
  if (fs.existsSync(cfgPath)) data = JSON.parse(fs.readFileSync(cfgPath, "utf8") || "{}");
} catch { data = {}; }
if (!data.mcpServers || typeof data.mcpServers !== "object") data.mcpServers = {};
data.mcpServers["agy-fleet"] = { command: nodeBin, args: [mcpScript] };
fs.writeFileSync(cfgPath, JSON.stringify(data, null, 2) + "\n", "utf8");
' "$MCP_CFG" "$NODE_BIN" "$MCP_SCRIPT" 2>/dev/null && echo "   ✓ Registered MCP server 'agy-fleet' in ${MCP_CFG}" || true
fi

# Ensure PATH in shell startup
for rc in "${HOME}/.bashrc" "${HOME}/.zshrc"; do
  if [ -f "$rc" ]; then
    if ! grep -q '\.local/bin' "$rc" 2>/dev/null; then
      echo 'export PATH="${HOME}/.local/share/mise/shims:${HOME}/.local/bin:${HOME}/.opencode/bin:${HOME}/.npm-global/bin:${PATH}"' >> "$rc"
    fi
  fi
done

# Register Default Workspaces
WS_REG="${HOME}/.gemini/config/orchestrator-workspaces.json"
DEFAULT_WS="${HOME}/Development/messaging-agent"
if [ ! -f "$WS_REG" ]; then
  if [ -d "$DEFAULT_WS" ]; then
    echo "[\"${DEFAULT_WS}\"]" > "$WS_REG"
    echo "   ✓ Created workspace registry with ${DEFAULT_WS}"
  else
    echo "[]" > "$WS_REG"
  fi
elif [ -d "$DEFAULT_WS" ] && command -v jq >/dev/null 2>&1; then
  TMP_WS=$(mktemp)
  jq --arg ws "$DEFAULT_WS" 'if index($ws) then . else . + [$ws] end' "$WS_REG" > "$TMP_WS" 2>/dev/null && mv "$TMP_WS" "$WS_REG" || rm -f "$TMP_WS"
  echo "   ✓ Registered ${DEFAULT_WS} in ${WS_REG}"
fi

# Configure 1x Daily systemd --user timer (safety fallback) + real-time SSE Push Daemon
SYSTEMD_USER_DIR="${HOME}/.config/systemd/user"
mkdir -p "$SYSTEMD_USER_DIR"
cat > "${SYSTEMD_USER_DIR}/agy-orchestrator-sync.service" <<EOF
[Unit]
Description=Antigravity Orchestrator Architecture Sync (Daily Safety Fallback)
After=network-online.target

[Service]
Type=oneshot
Environment=HOME=${HOME}
Environment=PATH=${HOME}/.local/share/mise/shims:${HOME}/.local/bin:${HOME}/.opencode/bin:${HOME}/.npm-global/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ExecStart=${HOME}/.local/bin/agy-arch-sync --quiet
EOF

cat > "${SYSTEMD_USER_DIR}/agy-orchestrator-sync.timer" <<EOF
[Unit]
Description=Run Antigravity Orchestrator Architecture Sync once daily (safety fallback)

[Timer]
OnCalendar=daily
Persistent=true
RandomizedDelaySec=120
Unit=agy-orchestrator-sync.service

[Install]
WantedBy=timers.target
EOF

if [ -n "$NODE_BIN" ] && [ -f "${FLEET_LIB}/agy-sync-daemon.js" ]; then
  cat > "${SYSTEMD_USER_DIR}/agy-sync-daemon.service" <<EOF
[Unit]
Description=Antigravity Real-Time SSE Fleet Push Daemon
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment=HOME=${HOME}
Environment=PATH=${HOME}/.local/share/mise/shims:${HOME}/.local/bin:${HOME}/.opencode/bin:${HOME}/.npm-global/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ExecStart=${NODE_BIN} ${FLEET_LIB}/agy-sync-daemon.js
Restart=always
RestartSec=3

[Install]
WantedBy=default.target
EOF
fi

if command -v systemctl >/dev/null 2>&1; then
  systemctl --user daemon-reload 2>/dev/null || true
  systemctl --user enable --now agy-orchestrator-sync.timer 2>/dev/null || true
  echo "   ✓ Enabled systemd --user timer: agy-orchestrator-sync.timer (1x Daily + Persistent)"
  if [ -f "${SYSTEMD_USER_DIR}/agy-sync-daemon.service" ] && [ -f "${HOME}/.gemini/config/fleet-sync.json" ]; then
    systemctl --user enable --now agy-sync-daemon.service 2>/dev/null || true
    systemctl --user restart agy-sync-daemon.service 2>/dev/null || true
    echo "   ✓ Enabled & started systemd --user service: agy-sync-daemon.service (Real-Time SSE Push)"
  elif [ -f "${SYSTEMD_USER_DIR}/agy-sync-daemon.service" ]; then
    systemctl --user enable agy-sync-daemon.service 2>/dev/null || true
    echo "   ℹ️ Enabled agy-sync-daemon.service (will connect once ~/.gemini/config/fleet-sync.json is configured)"
  fi
fi

date +%s > "${HOME}/.gemini/config/.last-orchestrator-sync"

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
