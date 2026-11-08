#!/usr/bin/env bash
# =============================================================================
# Install Antigravity Universal Root Gatekeeper Service (agy-gatekeeper)
# =============================================================================
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "❌ This installer must be run as root (or via sudo):"
  echo "   sudo $0"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER_SRC="${SCRIPT_DIR}/server.js"
SERVICE_SRC="${SCRIPT_DIR}/agy-gatekeeper.service"

INSTALL_LIB="/usr/local/lib/agy-gatekeeper"
CONFIG_DIR="/etc/agy-gatekeeper"
STATE_DIR="/var/lib/agy-gatekeeper"
SYSTEMD_DIR="/etc/systemd/system"

echo "🔧 Installing agy-gatekeeper daemon..."

# 1. Directories
mkdir -p "$INSTALL_LIB"
mkdir -p "$CONFIG_DIR"
mkdir -p "$STATE_DIR"
chmod 755 "$INSTALL_LIB"
chmod 700 "$CONFIG_DIR"
chmod 755 "$STATE_DIR"

# 2. Server binary & service file
cp -f "$SERVER_SRC" "${INSTALL_LIB}/server.js"
chmod 755 "${INSTALL_LIB}/server.js"
chown -R root:root "$INSTALL_LIB"

cp -f "$SERVICE_SRC" "${SYSTEMD_DIR}/agy-gatekeeper.service"
chmod 644 "${SYSTEMD_DIR}/agy-gatekeeper.service"
chown root:root "${SYSTEMD_DIR}/agy-gatekeeper.service"

# 3. Reload & restart systemd service
echo "🔄 Reloading systemd and enabling agy-gatekeeper.service..."
systemctl daemon-reload
systemctl enable --now agy-gatekeeper.service
systemctl restart agy-gatekeeper.service

# 4. Verification
sleep 1
if curl -sf "http://127.0.0.1:18099/api/gatekeeper/health" >/dev/null 2>&1; then
  echo "✅ agy-gatekeeper.service successfully installed and running on 127.0.0.1:18099!"
else
  echo "⚠️  agy-gatekeeper.service installed, but health check did not respond immediately."
  echo "   Check: systemctl status agy-gatekeeper.service"
fi
