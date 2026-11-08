#!/usr/bin/env bash
# =============================================================================
# Install Antigravity Universal Gatekeeper Service (agy-gatekeeper)
# =============================================================================
# Supports both:
#   - Root system service (`/etc/systemd/system/agy-gatekeeper.service`) when run via sudo/root
#   - User systemd fallback (`~/.config/systemd/user/agy-gatekeeper.service`) when `--user` is passed
#     or when non-root and passwordless sudo is unavailable.
# =============================================================================
set -euo pipefail

TARGET_USER="${SUDO_USER:-$(id -un)}"
USER_HOME="$(getent passwd "$TARGET_USER" 2>/dev/null | cut -d: -f6 || echo "${HOME:-/home/nick}")"
export PATH="${USER_HOME}/.local/share/mise/shims:${USER_HOME}/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"

USER_MODE=0
if [ "${1:-}" = "--user" ]; then
  USER_MODE=1
elif [ "$(id -u)" -ne 0 ]; then
  if sudo -n true 2>/dev/null; then
    exec sudo bash "$0" "$@"
  else
    USER_MODE=1
  fi
fi

resolve_node_bin() {
  local cand=""
  cand=$(ls -d "${USER_HOME}"/.local/share/mise/installs/node/*/bin/node 2>/dev/null | sort -V | tail -n 1 || true)
  if [ -n "$cand" ] && [ -x "$cand" ]; then
    echo "$cand"
    return 0
  fi
  if [ -x "${USER_HOME}/.local/share/mise/shims/node" ]; then
    echo "${USER_HOME}/.local/share/mise/shims/node"
    return 0
  fi
  if command -v node >/dev/null 2>&1; then
    command -v node
    return 0
  fi
  for p in /usr/bin/node /usr/local/bin/node; do
    if [ -x "$p" ]; then
      echo "$p"
      return 0
    fi
  done
  return 1
}

NODE_BIN="$(resolve_node_bin || true)"
if [ -z "$NODE_BIN" ]; then
  echo "❌ ERROR: Could not locate node binary on system." >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$(realpath "${BASH_SOURCE[0]}")")" && pwd)"
SERVER_SRC="${SCRIPT_DIR}/server.js"

if [ "$USER_MODE" -eq 0 ]; then
  INSTALL_LIB="/usr/local/lib/agy-gatekeeper"
  CONFIG_DIR="/etc/agy-gatekeeper"
  STATE_DIR="/var/lib/agy-gatekeeper"
  SYSTEMD_DIR="/etc/systemd/system"

  echo "🔧 Installing root agy-gatekeeper daemon (node: ${NODE_BIN})..."

  mkdir -p "$INSTALL_LIB" "$CONFIG_DIR" "$STATE_DIR"
  chmod 755 "$INSTALL_LIB" "$STATE_DIR"
  chmod 700 "$CONFIG_DIR"

  cp -f "$SERVER_SRC" "${INSTALL_LIB}/server.js"
  chmod 755 "${INSTALL_LIB}/server.js"
  chown -R root:root "$INSTALL_LIB"

  cat <<EOF > "${SYSTEMD_DIR}/agy-gatekeeper.service"
[Unit]
Description=Antigravity Universal Multi-Workspace Gatekeeper Enforcement Daemon
After=network.target

[Service]
Type=simple
User=root
Group=root
ExecStart=${NODE_BIN} ${INSTALL_LIB}/server.js
Restart=always
RestartSec=2
Environment=NODE_ENV=production
Environment=PATH=${USER_HOME}/.local/share/mise/shims:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

[Install]
WantedBy=multi-user.target
EOF
  chmod 644 "${SYSTEMD_DIR}/agy-gatekeeper.service"
  chown root:root "${SYSTEMD_DIR}/agy-gatekeeper.service"

  echo "🔄 Reloading systemd and enabling agy-gatekeeper.service..."
  systemctl daemon-reload
  systemctl enable --now agy-gatekeeper.service
  systemctl restart agy-gatekeeper.service
else
  INSTALL_LIB="${USER_HOME}/.local/lib/agy-gatekeeper"
  CONFIG_DIR="${USER_HOME}/.config/agy-gatekeeper"
  STATE_DIR="${USER_HOME}/.local/share/agy-gatekeeper"
  SYSTEMD_USER_DIR="${USER_HOME}/.config/systemd/user"

  echo "🔧 Installing user-level agy-gatekeeper.service (node: ${NODE_BIN})..."

  mkdir -p "$INSTALL_LIB" "$CONFIG_DIR" "$STATE_DIR" "$SYSTEMD_USER_DIR"
  chmod 755 "$INSTALL_LIB" "$STATE_DIR"
  chmod 700 "$CONFIG_DIR"

  cp -f "$SERVER_SRC" "${INSTALL_LIB}/server.js"
  chmod 755 "${INSTALL_LIB}/server.js"

  cat <<EOF > "${SYSTEMD_USER_DIR}/agy-gatekeeper.service"
[Unit]
Description=Antigravity Universal Multi-Workspace Gatekeeper Enforcement Daemon (User Mode)
After=network.target

[Service]
Type=simple
ExecStart=${NODE_BIN} ${INSTALL_LIB}/server.js
Restart=always
RestartSec=2
Environment=NODE_ENV=production
Environment=HOME=${USER_HOME}
Environment=PATH=${USER_HOME}/.local/share/mise/shims:${USER_HOME}/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

[Install]
WantedBy=default.target
EOF
  chmod 644 "${SYSTEMD_USER_DIR}/agy-gatekeeper.service"

  echo "🔄 Reloading systemd --user and enabling agy-gatekeeper.service..."
  systemctl --user daemon-reload
  systemctl --user enable --now agy-gatekeeper.service
  systemctl --user restart agy-gatekeeper.service
fi

sleep 1
if curl -sf "http://127.0.0.1:18099/api/gatekeeper/health" >/dev/null 2>&1; then
  echo "✅ agy-gatekeeper.service successfully installed and running on 127.0.0.1:18099!"
else
  echo "⚠️  agy-gatekeeper.service installed, but health check did not respond immediately."
  if [ "$USER_MODE" -eq 0 ]; then
    echo "   Check: systemctl status agy-gatekeeper.service"
  else
    echo "   Check: systemctl --user status agy-gatekeeper.service"
  fi
fi
