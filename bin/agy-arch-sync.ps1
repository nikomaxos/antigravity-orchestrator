<#
.SYNOPSIS
  Antigravity Architecture Synchronizer (Windows PowerShell: `agy-arch-sync.ps1`)
.DESCRIPTION
  Synchronizes model matrix, dynamic routing rules, global skills, and registered
  workspaces across Windows and multi-platform environments.
#>
[CmdletBinding()]
param(
    [switch]$Quiet = $false,
    [string]$WorkspacePath = ""
)

$ErrorActionPreference = "Continue"

function Write-Log {
    param([string]$Message, [string]$Color = "Cyan")
    if (-not $Quiet) {
        Write-Host $Message -ForegroundColor $Color
    }
}

$userHome = $HOME
if (-not $userHome) { $userHome = $env:USERPROFILE }

$configDir = Join-Path $userHome ".gemini\config"
$stampFile = Join-Path $configDir ".last-orchestrator-sync"
$wsRegistry = Join-Path $configDir "orchestrator-workspaces.json"

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
    Write-Log "⚠️ Repository not found in candidates ($($repoCandidates -join ', '))." "Yellow"
    exit 0
}

Write-Log "🔄 Checking for updates in $repoDir..." "Cyan"

# Pull latest origin/main with HTTPS fallback
try {
    $remoteUrl = git -C "$repoDir" remote get-url origin 2>$null
    if ($remoteUrl) {
        # Test git fetch
        $fetchRes = git -C "$repoDir" fetch origin main 2>&1
        if ($LASTEXITCODE -ne 0 -and $remoteUrl -like "git@*") {
            Write-Log "   ℹ️ SSH fetch failed; trying HTTPS fallback remote..." "DarkGray"
            git -C "$repoDir" remote set-url origin "https://github.com/nikomaxos/antigravity-orchestrator.git" 2>$null
            git -C "$repoDir" fetch origin main 2>$null
        }
        git -C "$repoDir" merge --ff-only origin/main 2>$null | Out-Null
    }
} catch {
    Write-Log "   ℹ️ Git pull skipped or working tree already updated." "DarkGray"
}

# 0. Register workspace if provided
if ($WorkspacePath -and (Test-Path $WorkspacePath)) {
    try {
        $resolvedWs = (Resolve-Path $WorkspacePath).Path
        $wsList = @()
        if (Test-Path $wsRegistry) {
            $wsList = @(Get-Content -Path $wsRegistry -Raw -Encoding UTF8 | ConvertFrom-Json)
        }
        if ($wsList -notcontains $resolvedWs) {
            $wsList += $resolvedWs
            $wsList | ConvertTo-Json | Set-Content -Path $wsRegistry -Encoding UTF8
            Write-Log "   -> Registered workspace: $resolvedWs" "Green"
        }
    } catch {}
}

# 1. Sync global rules & routing
Write-Log "📦 Syncing global configs & skills into $configDir..." "Cyan"
New-Item -ItemType Directory -Path $configDir -Force | Out-Null

$srcModelRouting = Join-Path $repoDir "global\gemini\config\model-routing.json"
if (Test-Path $srcModelRouting) {
    Copy-Item -Path $srcModelRouting -Destination (Join-Path $configDir "model-routing.json") -Force
}

$srcAgents = Join-Path $repoDir "global\gemini\config\AGENTS.md"
if (Test-Path $srcAgents) {
    Copy-Item -Path $srcAgents -Destination (Join-Path $configDir "AGENTS.md") -Force
}

$srcGemini = Join-Path $repoDir "global\gemini\config\GEMINI.md"
if (Test-Path $srcGemini) {
    Copy-Item -Path $srcGemini -Destination (Join-Path $configDir "GEMINI.md") -Force
    Copy-Item -Path $srcGemini -Destination (Join-Path $userHome ".gemini\GEMINI.md") -Force -ErrorAction SilentlyContinue
}

# Sync global skills dynamically
$skillsBaseDir = Join-Path $configDir "skills"
New-Item -ItemType Directory -Path $skillsBaseDir -Force | Out-Null
$globalSkillsSrc = Join-Path $repoDir "global\gemini\config\skills"
if (Test-Path $globalSkillsSrc) {
    Get-ChildItem -Path $globalSkillsSrc -Directory | ForEach-Object {
        $destSkill = Join-Path $skillsBaseDir $_.Name
        New-Item -ItemType Directory -Path $destSkill -Force | Out-Null
        Copy-Item -Path "$($_.FullName)\*" -Destination $destSkill -Recurse -Force
    }
}

# Sync global workflows
$srcWorkflows = Join-Path $repoDir "global\gemini\config\workflows"
if (Test-Path $srcWorkflows) {
    $destWorkflows = Join-Path $configDir "workflows"
    $destGlobalWorkflows = Join-Path $configDir "global_workflows"
    New-Item -ItemType Directory -Path $destWorkflows -Force | Out-Null
    New-Item -ItemType Directory -Path $destGlobalWorkflows -Force | Out-Null
    Copy-Item -Path "$srcWorkflows\*" -Destination $destWorkflows -Recurse -Force
    Copy-Item -Path "$srcWorkflows\*" -Destination $destGlobalWorkflows -Recurse -Force
}

# 2. Sync registered workspaces
$syncScripts = @(
    "codex-lib.sh",
    "frontier-orchestrate.sh",
    "codex-orchestrate.sh",
    "claude-orchestrate.sh",
    "opencode-orchestrate.sh",
    "codex-rca.sh",
    "gemini-quota-mode.sh"
)

if (Test-Path $wsRegistry) {
    try {
        $workspaces = @(Get-Content -Path $wsRegistry -Raw -Encoding UTF8 | ConvertFrom-Json)
        foreach ($ws in $workspaces) {
            if ($ws -and (Test-Path $ws) -and (Test-Path (Join-Path $ws ".agents"))) {
                Write-Log "   -> Syncing workspace: $ws" "DarkGray"
                $wsConfig = Join-Path $ws ".agents\config"
                $wsScripts = Join-Path $ws ".agents\scripts"
                New-Item -ItemType Directory -Path $wsConfig -Force | Out-Null
                New-Item -ItemType Directory -Path $wsScripts -Force | Out-Null

                if (Test-Path $srcModelRouting) {
                    Copy-Item -Path $srcModelRouting -Destination (Join-Path $wsConfig "model-routing.json") -Force
                }

                foreach ($s in $syncScripts) {
                    $srcS = Join-Path $repoDir "workspace-template\.agents\scripts\$s"
                    if (Test-Path $srcS) {
                        Copy-Item -Path $srcS -Destination (Join-Path $wsScripts $s) -Force
                    }
                }

                # Sync workspace skills
                $srcWsSkills = Join-Path $repoDir "workspace-template\.agents\skills"
                if (Test-Path $srcWsSkills) {
                    $destWsSkills = Join-Path $ws ".agents\skills"
                    New-Item -ItemType Directory -Path $destWsSkills -Force | Out-Null
                    Copy-Item -Path "$srcWsSkills\*" -Destination $destWsSkills -Recurse -Force
                }

                # Sync workspace workflows
                $srcWsWorkflows = Join-Path $repoDir "workspace-template\.agents\workflows"
                if (Test-Path $srcWsWorkflows) {
                    $destWsWorkflows = Join-Path $ws ".agents\workflows"
                    New-Item -ItemType Directory -Path $destWsWorkflows -Force | Out-Null
                    Copy-Item -Path "$srcWsWorkflows\*" -Destination $destWsWorkflows -Recurse -Force
                }
            }
        }
    } catch {}
}

# 3. Stamp last sync time (epoch seconds)
$epoch = [int64]((Get-Date).ToUniversalTime() - (Get-Date "1970-01-01 00:00:00")).TotalSeconds
Set-Content -Path $stampFile -Value $epoch -Encoding UTF8
Write-Log "✅ Architecture sync complete! Stamped $stampFile" "Green"
