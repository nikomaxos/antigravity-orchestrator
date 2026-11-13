#!/usr/bin/env bash
# =============================================================================
# Antigravity Turbo Velocity & Zero-Popup Configuration (`configure-antigravity-turbo.sh`)
# =============================================================================
# Sets agent permissions to TURBO and enables eager auto-execution and non-workspace
# file access without repetitive manual prompt confirmations (Google CitC Velocity).
# =============================================================================
set -euo pipefail

USER_HOME="${HOME:-$(getent passwd "$(id -un)" 2>/dev/null | cut -d: -f6 || echo "/home/nick")}"
CONFIG_DIR="${USER_HOME}/.gemini/config"
CONFIG_FILE="${CONFIG_DIR}/config.json"

mkdir -p "$CONFIG_DIR"

if [ ! -f "$CONFIG_FILE" ]; then
  echo '{"userSettings":{}}' > "$CONFIG_FILE"
fi

# Create safety backup
STAMP=$(date +%Y%m%d%H%M%S)
cp -f "$CONFIG_FILE" "${CONFIG_FILE}.bak.${STAMP}" 2>/dev/null || true

# Merge Turbo settings cleanly using jq if available, otherwise python3
if command -v jq >/dev/null 2>&1; then
  # Read existing file, handle empty or malformed files gracefully
  TMP_JSON=$(mktemp)
  jq '
    .userSettings = (.userSettings // {}) |
    .userSettings.nonWorkspaceFileAccessPolicy = "AGENT_SETTING_POLICY_ALLOW" |
    .userSettings.allowCascadeAccessGitignoreFiles = true |
    .userSettings.autoExecutionPolicy = "CASCADE_COMMANDS_AUTO_EXECUTION_EAGER" |
    .userSettings.permissionPreset = "AGENT_PERMISSION_PRESET_TURBO" |
    .userSettings.enableTerminalSandbox = false
  ' "$CONFIG_FILE" > "$TMP_JSON" 2>/dev/null && mv "$TMP_JSON" "$CONFIG_FILE" || rm -f "$TMP_JSON"
elif command -v python3 >/dev/null 2>&1; then
  python3 -c '
import json, sys

path = sys.argv[1]
try:
    with open(path, "r", encoding="utf-8") as f:
        data = json.load(f)
except Exception:
    data = {}

if "userSettings" not in data or not isinstance(data["userSettings"], dict):
    data["userSettings"] = {}

data["userSettings"]["nonWorkspaceFileAccessPolicy"] = "AGENT_SETTING_POLICY_ALLOW"
data["userSettings"]["allowCascadeAccessGitignoreFiles"] = True
data["userSettings"]["autoExecutionPolicy"] = "CASCADE_COMMANDS_AUTO_EXECUTION_EAGER"
data["userSettings"]["permissionPreset"] = "AGENT_PERMISSION_PRESET_TURBO"
data["userSettings"]["enableTerminalSandbox"] = False

with open(path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
' "$CONFIG_FILE"
fi

echo "✅ Turbo CitC settings configured in ${CONFIG_FILE}"
