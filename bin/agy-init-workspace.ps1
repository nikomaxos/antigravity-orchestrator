# =============================================================================
# Antigravity Workspace Initializer (Windows PowerShell: `agy-init-workspace.ps1`)
# =============================================================================
# Initializes any Git repository with the Antigravity Multi-Model Orchestrator,
# programmatic enforcement hooks, and hard gatekeeper integration.
#
# Supports:
#   - Generic repositories
#   - Home Assistant (Oraiokastro) & Antigravity Brain workspaces
#   - Windows PowerShell 5.1 & PowerShell Core 7+
#   - Strict preservation of existing .agents/rules/ (e.g. ha_credentials.md)
# =============================================================================
[CmdletBinding()]
param(
    [Parameter(Position = 0, Mandatory = $false)]
    [string]$WorkspacePath = "."
)

$ErrorActionPreference = "Stop"

$userHome = $HOME
if (-not $userHome) { $userHome = $env:USERPROFILE }

$scriptDir = $PSScriptRoot
if (-not $scriptDir) {
    $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
}
if (-not $scriptDir) {
    $scriptDir = (Get-Location).Path
}

$repoRoot = Split-Path -Parent $scriptDir
$templateCandidates = @(
    (Join-Path $repoRoot "workspace-template"),
    (Join-Path $userHome ".local\share\antigravity-orchestrator\workspace-template"),
    (Join-Path $userHome ".local\lib\agy-gatekeeper\workspace-template"),
    (Join-Path $userHome "Development\antigravity-orchestrator\workspace-template"),
    "C:\Users\parda\Development\antigravity-orchestrator\workspace-template"
)
$templateDir = ""
foreach ($cand in $templateCandidates) {
    if (Test-Path $cand) {
        $templateDir = $cand
        break
    }
}
if (-not $templateDir) {
    Write-Error "Could not locate workspace-template directory. Please check installation."
    exit 1
}

# 1. Resolve Target Directory
if (-not (Test-Path $WorkspacePath)) {
    New-Item -ItemType Directory -Path $WorkspacePath -Force | Out-Null
}
$targetDir = [System.IO.Path]::GetFullPath($WorkspacePath)

Write-Host "`n🚀 Initializing Antigravity Orchestrator in: $targetDir" -ForegroundColor Cyan

# 2. Verify / Init Git
$gitDir = Join-Path $targetDir ".git"
if (-not (Test-Path $gitDir)) {
    Write-Host "📦 Initializing Git repository in $targetDir..." -ForegroundColor Yellow
    git -C "$targetDir" init -b main
}

# 3. Create Required Directory Structure (PS 5.1 safe)
$agentsDir = Join-Path $targetDir ".agents"
$agentStateDir = Join-Path $targetDir ".agent-state"
$agentReportsDir = Join-Path $targetDir ".agent-reports\codex"
$rulesDir = Join-Path $agentsDir "rules"
$scriptsDir = Join-Path $agentsDir "scripts"
$skillsDir = Join-Path $agentsDir "skills"
$configDir = Join-Path $agentsDir "config"
$gitHooksDir = Join-Path $targetDir ".git\hooks"

$dirsToCreate = @($agentsDir, $agentStateDir, $agentReportsDir, $rulesDir, $scriptsDir, $skillsDir, $configDir, $gitHooksDir)
foreach ($d in $dirsToCreate) {
    if (-not (Test-Path $d)) {
        New-Item -ItemType Directory -Force -Path $d | Out-Null
    }
}

# 4. Copy Control Plane Components
Copy-Item -Path (Join-Path $templateDir ".agents\hooks.json") -Destination $agentsDir -Force
Copy-Item -Path (Join-Path $templateDir ".agents\scripts\*") -Destination $scriptsDir -Recurse -Force
Copy-Item -Path (Join-Path $templateDir ".agents\skills\*") -Destination $skillsDir -Recurse -Force
$srcRouting = Join-Path $templateDir ".agents\config\model-routing.json"
if (Test-Path $srcRouting) {
    Copy-Item -Path $srcRouting -Destination (Join-Path $configDir "model-routing.json") -Force
}
Write-Host "   ✓ Installed .agents/hooks.json" -ForegroundColor Green
Write-Host "   ✓ Installed .agents/scripts/" -ForegroundColor Green
Write-Host "   ✓ Installed .agents/skills/" -ForegroundColor Green
Write-Host "   ✓ Installed .agents/config/model-routing.json" -ForegroundColor Green

# 5. Safe Rules Copy: NEVER overwrite or delete existing rules!
$templateRules = Get-ChildItem -Path (Join-Path $templateDir ".agents\rules") -File
foreach ($rule in $templateRules) {
    $destRule = Join-Path $rulesDir $rule.Name
    if (-not (Test-Path $destRule)) {
        Copy-Item -Path $rule.FullName -Destination $destRule
        Write-Host "   ✓ Installed rule: $($rule.Name)" -ForegroundColor Green
    } else {
        Write-Host "   ℹ️ Preserved existing rule: $($rule.Name)" -ForegroundColor DarkGray
    }
}

# 6. Detect Home Assistant Workspace
$isHaWorkspace = $false
if ((Test-Path (Join-Path $targetDir "repo\antigravity_brain")) -or
    (Test-Path (Join-Path $targetDir "antigravity_addon")) -or
    (Test-Path (Join-Path $targetDir "antigravity_component")) -or
    (Test-Path (Join-Path $rulesDir "ha_credentials.md")) -or
    ($targetDir -match "([\\/]|^)ha$") -or
    ($targetDir -match "([\\/]|^)ha[\\/]")) {
    $isHaWorkspace = $true
}

# 7. Protect Sensitive Credentials in .gitignore
$gitignorePath = Join-Path $targetDir ".gitignore"
$credPattern = ".agents/rules/*credentials*.md"
if (-not (Test-Path $gitignorePath)) {
    $initialGitignore = @"
# Home Assistant credentials & sensitive rules
$credPattern
.agent-state/
.agent-reports/
.last-staging-deploy
"@
    Set-Content -Path $gitignorePath -Value $initialGitignore -Encoding UTF8
    Write-Host "   ✓ Created .gitignore with credentials protection" -ForegroundColor Green
} else {
    $existingGitignore = Get-Content -Path $gitignorePath -Raw
    if ($existingGitignore -notmatch "\*credentials\*\.md") {
        $appendGitignore = @"

# Home Assistant credentials & sensitive rules
$credPattern
.agent-state/
.agent-reports/
.last-staging-deploy
"@
        Add-Content -Path $gitignorePath -Value $appendGitignore -Encoding UTF8
        Write-Host "   ✓ Appended credentials protection to .gitignore" -ForegroundColor Green
    } else {
        Write-Host "   ℹ️ .gitignore already protects credentials" -ForegroundColor DarkGray
    }
}

# 8. Manage .agents/PROJECT_KNOWLEDGE.md
$pkPath = Join-Path $agentsDir "PROJECT_KNOWLEDGE.md"
if (-not (Test-Path $pkPath)) {
    if ($isHaWorkspace) {
        $haKnowledge = @"
# Project Architecture & Knowledge Index — Home Assistant (Oraiokastro) & Antigravity Brain

## 1. Overview & Architecture Index
This repository houses the Home Assistant (Oraiokastro) integration and Antigravity Brain add-on ecosystem, protected by the Antigravity Multi-Model Orchestrator and Gatekeeper enforcement layer.

### Core Architecture Components
- **Root Project**: Home Assistant workspace ($targetDir).
- **Antigravity Brain Add-on**: `repo/antigravity_brain` & `antigravity_addon` (Supervisor add-on running the Antigravity Brain intelligence service).
- **Antigravity Custom Component**: `antigravity_component` (`custom_components/antigravity` integration inside Home Assistant Core).
- **Agent Rules & HA Credentials**: `.agents/rules/ha_credentials.md` (loaded on demand for Home Assistant API/SSH/deployment operations, strictly ignored by git and never committed).
- **Enforcement Layer**: `.agents/hooks.json`, `.agents/scripts/`, `.agents/rules/`, and `.agent-state/`.
- **Knowledge Vault**: `.agents/PROJECT_KNOWLEDGE.md` (architecture facts & changelog).
- **Skills Vault**: `.agents/skills/*/SKILL.md` (reusable operational playbooks & procedures).

---

## 2. Pure Zero-Hands-On Orchestrator & 4-Pool Model Routing
1. **Universal Parent Orchestrator (Default: `Gemini 4 Carbon Medium`)**: Operates strictly as a **Pure Dispatcher / Orchestrator** (0 hands-on file reads/edits/builds in parent context, maintaining parent turns at <35K tokens with ~1s latency).
2. **External-First Frontier Offload (`frontier-orchestrate.sh`)**:
   - `T1` Fast Explorer (`Model: "flash"` — `Gemini 3.8 Flash`, `Flash I/O` thinking): Codebase exploration, log slicing, read-only queries.
   - `T2` UI / Frontend / Tests (`frontier-orchestrate.sh --tier ui`: Claude Sonnet 4.6 -> Codex gpt-5.6-terra med -> DeepSeek-V4-Pro).
   - `T3` Multi-Service / Backend (`frontier-orchestrate.sh --tier backend`: Codex gpt-6-astra high -> Claude Sonnet 4.6 -> DeepSeek-V4-Pro).
   - `T4` Critical Architecture & Security (`codex-rca.sh` / `frontier-orchestrate.sh --tier deep`: Codex gpt-6-astra xhigh -> Claude Opus 4.6 high -> DeepSeek-V4-Pro).
   - Release & Gatekeeper Worker: Executes QA, Regression, Docs, Vault, Skills, and Review gates.
3. **Root Gatekeeper (`agy-gatekeeper.service` on `127.0.0.1:18099`)**: Cryptographic HMAC signing and verification of `.agent-state/*.json`.

---

## 3. Operating Rules & Invariants
1. **Single Writer**: Antigravity is the only agent with write access; external CLIs (Codex, Claude Code, OpenCode) execute strictly read-only.
2. **HA Credentials Security**: Never commit or expose passwords, bearer tokens, or SSH keys from `.agents/rules/ha_credentials.md`.
3. **Execution Evidence**: Never declare a task complete or a check passed without concrete execution output.
4. **Autonomous Skills Distillation**: Update or synthesize `.agents/skills/<name>/SKILL.md` whenever new operational procedures or debugging playbooks are discovered.

---

## 📝 Recent Outcomes
<!-- Chronological record of completed architectural changes, features, and fixes -->
- Initialized Home Assistant (Oraiokastro) & Antigravity Brain workspace with Antigravity 4-Pool Multi-Model Orchestrator & agy-gatekeeper enforcement.
"@
        Set-Content -Path $pkPath -Value $haKnowledge -Encoding UTF8
        Write-Host "📄 Created tailored Home Assistant .agents/PROJECT_KNOWLEDGE.md" -ForegroundColor Green
    } else {
        Copy-Item -Path (Join-Path $templateDir ".agents\PROJECT_KNOWLEDGE.md") -Destination $pkPath
        Write-Host "📄 Created .agents/PROJECT_KNOWLEDGE.md" -ForegroundColor Green
    }
} else {
    Write-Host "ℹ️  Preserved existing .agents/PROJECT_KNOWLEDGE.md" -ForegroundColor DarkGray
}

# 9. Manage AGENTS.md
$agentsMdPath = Join-Path $targetDir "AGENTS.md"
if (-not (Test-Path $agentsMdPath)) {
    Copy-Item -Path (Join-Path $templateDir "AGENTS.md") -Destination $agentsMdPath
    Write-Host "📄 Created AGENTS.md" -ForegroundColor Green
} else {
    Write-Host "ℹ️  Preserved existing AGENTS.md" -ForegroundColor DarkGray
}

if ($isHaWorkspace) {
    $agentsContent = Get-Content -Path $agentsMdPath -Raw
    if ($agentsContent -notmatch "ha_credentials\.md") {
        $haAgentsRule = @"

- **HOME ASSISTANT CREDENTIALS & SENSITIVE RULES**: When executing Home Assistant API, SSH, or deployment tasks, load `.agents/rules/ha_credentials.md` on demand for endpoints, bearer tokens, and secrets. NEVER print secrets or commit this file to git.
"@
        Add-Content -Path $agentsMdPath -Value $haAgentsRule -Encoding UTF8
        Write-Host "   ✓ Added Home Assistant credentials reference to AGENTS.md" -ForegroundColor Green
    }
}

# 10. Install Git Hooks (Pre-Commit & Post-Commit)
$preCommitPath = Join-Path $gitHooksDir "pre-commit"
$postCommitPath = Join-Path $gitHooksDir "post-commit"

$preCommitContent = @'
#!/usr/bin/env bash
# Antigravity Gatekeeper Native Pre-Commit Hook
set -euo pipefail
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
if command -v cygpath >/dev/null 2>&1; then
  REPO_ROOT="$(cygpath -m "$REPO_ROOT" 2>/dev/null || echo "$REPO_ROOT")"
fi
exec bash "${REPO_ROOT}/.agents/scripts/commit-gate.sh" --git-hook
'@

$postCommitContent = @'
#!/usr/bin/env bash
# Antigravity Gatekeeper Native Post-Commit Hook
set -euo pipefail
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
if command -v cygpath >/dev/null 2>&1; then
  REPO_ROOT="$(cygpath -m "$REPO_ROOT" 2>/dev/null || echo "$REPO_ROOT")"
fi
HEAD_SHA=$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || echo "")
if [ -n "$HEAD_SHA" ]; then
  curl -sf -X POST -H "Content-Type: application/json" \
    -d "{\"workspace\":\"${REPO_ROOT}\",\"head\":\"${HEAD_SHA}\"}" \
    "http://127.0.0.1:18099/api/gatekeeper/register-commit" >/dev/null 2>&1 || true
fi
exit 0
'@

Set-Content -Path $preCommitPath -Value $preCommitContent -NoNewline -Encoding UTF8
Set-Content -Path $postCommitPath -Value $postCommitContent -NoNewline -Encoding UTF8
Write-Host "   ✓ Installed .git/hooks/pre-commit & post-commit" -ForegroundColor Green

# 11. Apply TCB Filesystem ACL Lock (Layer 3) if running as Administrator
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if ($isAdmin) {
    Write-Host "🔒 Applying TCB Filesystem ACL Lock (NTFS icacls RX)..." -ForegroundColor Cyan
    $targetUser = $env:USERNAME
    $protectedFiles = @(
        (Join-Path $agentsDir "hooks.json"),
        (Join-Path $scriptsDir "commit-gate.sh"),
        (Join-Path $scriptsDir "protect-enforcement.sh"),
        (Join-Path $scriptsDir "verify-gates.sh"),
        (Join-Path $gitHooksDir "pre-commit"),
        (Join-Path $gitHooksDir "post-commit")
    )
    foreach ($pf in $protectedFiles) {
        if (Test-Path $pf) {
            icacls "$pf" /inheritance:r /grant:r "NT AUTHORITY\SYSTEM:(F)" "BUILTIN\Administrators:(F)" "${targetUser}:(RX)" | Out-Null
        }
    }
    Write-Host "   ✓ Locked enforcement hooks with NTFS ACLs: read+execute only for $targetUser" -ForegroundColor Green
}

# 12. Register Workspace in ~/.gemini/config/orchestrator-workspaces.json
$geminiConfigDir = Join-Path $userHome ".gemini\config"
$wsRegFile = Join-Path $geminiConfigDir "orchestrator-workspaces.json"
try {
    New-Item -ItemType Directory -Path $geminiConfigDir -Force | Out-Null
    $registered = @()
    if (Test-Path $wsRegFile) {
        $registered = @(Get-Content -Path $wsRegFile -Raw -Encoding UTF8 | ConvertFrom-Json)
    }
    if ($registered -notcontains $targetDir) {
        $registered += $targetDir
        $registered | ConvertTo-Json | Set-Content -Path $wsRegFile -Encoding UTF8
        Write-Host "   ✓ Registered workspace in $wsRegFile" -ForegroundColor Green
    }
} catch {}

# 13. Check Gatekeeper Service
Write-Host ""
try {
    $resp = Invoke-RestMethod -Uri "http://127.0.0.1:18099/api/gatekeeper/health" -Method Get -TimeoutSec 2 -ErrorAction Stop
    if ($resp.status -eq "UP") {
        Write-Host "✅ agy-gatekeeper is active and healthy on 127.0.0.1:18099." -ForegroundColor Green
    }
} catch {
    Write-Host "⚠️  agy-gatekeeper is NOT responding on 127.0.0.1:18099." -ForegroundColor Yellow
    Write-Host "   Run .\install.ps1 to start and register the AgyGatekeeper service." -ForegroundColor Yellow
}

Write-Host "`n🎉 Workspace initialized successfully!" -ForegroundColor Cyan
Write-Host "   - Target: $targetDir"
Write-Host "   - Mode: $(if ($isHaWorkspace) { 'Home Assistant (Oraiokastro)' } else { 'Generic Repository' })"
Write-Host "   - Credentials Protected: YES (.agents/rules/*credentials*.md in .gitignore)"
Write-Host "   - Gatekeeper: Port 18099"
