<#
.SYNOPSIS
  Antigravity Architecture Sync CLI (PowerShell: `architecture-sync.ps1`)
.DESCRIPTION
  Detects OS, pulls latest changes from GitHub, updates model-routing.json,
  syncs global and workspace scripts/skills, and checks gatekeeper health.
#>
[CmdletBinding()]
param(
    [string]$WorkspacePath = ""
)

$ErrorActionPreference = "Continue"

# 1. Detect Operating System
$osDesc = [System.Runtime.InteropServices.RuntimeInformation]::OSDescription
if (-not $osDesc) { $osDesc = "Windows (NT)" }

$userHome = $HOME
if (-not $userHome) { $userHome = $env:USERPROFILE }

$configDir = Join-Path $userHome ".gemini\config"
$repoCandidates = @(
    (Join-Path $userHome "Development\antigravity-orchestrator"),
    "C:\Users\parda\Development\antigravity-orchestrator",
    (Join-Path $env:LOCALAPPDATA "antigravity-orchestrator")
)
$repoDir = ""
foreach ($cand in $repoCandidates) {
    if (Test-Path $cand) {
        $repoDir = $cand
        break
    }
}

if (-not $repoDir) {
    $repoDir = Join-Path $userHome "Development\antigravity-orchestrator"
    Write-Host "ℹ️  Cloning repository into $repoDir..." -ForegroundColor Cyan
    New-Item -ItemType Directory -Path (Split-Path $repoDir) -Force | Out-Null
    git clone https://github.com/nikomaxos/antigravity-orchestrator.git "$repoDir"
}

if (-not $WorkspacePath) {
    $WorkspacePath = (Get-Location).Path
}

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "  Antigravity Architecture Synchronization (Windows)" -ForegroundColor Cyan
Write-Host "  OS: $osDesc" -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan

$oldSha = "unknown"
try {
    $oldSha = (git -C "$repoDir" rev-parse --short HEAD 2>$null).Trim()
} catch {}

# Pull latest origin/main with HTTPS fallback
try {
    $remoteUrl = git -C "$repoDir" remote get-url origin 2>$null
    if ($remoteUrl) {
        $fetchRes = git -C "$repoDir" fetch origin main 2>&1
        if ($LASTEXITCODE -ne 0 -and $remoteUrl -like "git@*") {
            git -C "$repoDir" remote set-url origin "https://github.com/nikomaxos/antigravity-orchestrator.git" 2>$null
            git -C "$repoDir" fetch origin main 2>$null
        }
        git -C "$repoDir" merge --ff-only origin/main 2>$null | Out-Null
    }
} catch {}

$newSha = $oldSha
try {
    $newSha = (git -C "$repoDir" rev-parse --short HEAD 2>$null).Trim()
} catch {}

# Run agy-arch-sync.ps1
$archSyncScript = Join-Path $repoDir "bin\agy-arch-sync.ps1"
if (Test-Path $archSyncScript) {
    & "$archSyncScript" -WorkspacePath "$WorkspacePath"
}

# Check Gatekeeper Health
$gkStatus = "Offline"
try {
    $res = Invoke-RestMethod -Uri "http://127.0.0.1:18099/api/gatekeeper/health" -TimeoutSec 2 -ErrorAction SilentlyContinue
    if ($res -and $res.ok) {
        $gkStatus = "Healthy / Active (127.0.0.1:18099)"
    }
} catch {}

# Check Model Routing
$routingInfo = "Unknown"
$modelRoutingPath = Join-Path $configDir "model-routing.json"
if (Test-Path $modelRoutingPath) {
    try {
        $mJson = Get-Content -Path $modelRoutingPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $routingInfo = "$($mJson.schema_version) ($($mJson.updated_at))"
    } catch {}
}

$transition = "$oldSha -> $newSha"
if ($oldSha -eq $newSha) {
    $transition = "Already up-to-date ($newSha)"
}

Write-Host ""
Write-Host "----------------------------------------------------------" -ForegroundColor DarkCyan
Write-Host "  Sync Results / Αποτελέσματα Συγχρονισμού" -ForegroundColor DarkCyan
Write-Host "----------------------------------------------------------" -ForegroundColor DarkCyan
Write-Host "  🖥️  OS:              $osDesc" -ForegroundColor White
Write-Host "  🔄 Git Version:     $transition" -ForegroundColor White
Write-Host "  🎛️  Model Routing:   $routingInfo" -ForegroundColor White
Write-Host "  📁 Workspace:       $WorkspacePath" -ForegroundColor White
Write-Host "  🛡️  Gatekeeper:      $gkStatus" -ForegroundColor White
Write-Host "  ⏱️  Timestamp:       $((Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'))" -ForegroundColor White
Write-Host "----------------------------------------------------------" -ForegroundColor DarkCyan
Write-Host "✅ Architecture sync complete." -ForegroundColor Green
