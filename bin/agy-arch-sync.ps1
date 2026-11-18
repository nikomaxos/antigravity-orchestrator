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
    [switch]$Force = $false,
    [string]$WorkspacePath = ""
)

$ErrorActionPreference = "Continue"

function Write-Utf8NoBom {
    param([string]$Path, [string]$Content)
    $parent = Split-Path -Parent $Path
    if ($parent -and -not (Test-Path $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $enc)
}

function Read-JsonNoBom {
    param([string]$Path)
    $raw = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
    if ($raw) { $raw = $raw.TrimStart([char]0xFEFF) }
    return ($raw | ConvertFrom-Json)
}

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
            $parsedWs = Read-JsonNoBom -Path $wsRegistry
            if ($parsedWs -is [System.Array]) { $wsList = @($parsedWs | Where-Object { $_ }) }
            elseif ($parsedWs) { $wsList = @([string]$parsedWs) }
        }
        if ($wsList -notcontains $resolvedWs) {
            $wsList += $resolvedWs
            Write-Utf8NoBom -Path $wsRegistry -Content ((ConvertTo-Json -InputObject ([string[]]$wsList)) + "`n")
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

# Sync helper binaries & fleet daemon/MCP scripts
$localBin = Join-Path $userHome ".local\bin"
New-Item -ItemType Directory -Path $localBin -Force | Out-Null
$srcBin = Join-Path $repoDir "bin"
if (Test-Path $srcBin) {
    Copy-Item -Path "$srcBin\*" -Destination $localBin -Recurse -Force -ErrorAction SilentlyContinue
}

$fleetLib = Join-Path $userHome ".local\lib\agy-fleet"
$srcFleet = Join-Path $repoDir "fleet"
if (Test-Path $srcFleet) {
    New-Item -ItemType Directory -Path $fleetLib -Force | Out-Null
    Copy-Item -Path "$srcFleet\*" -Destination $fleetLib -Recurse -Force -ErrorAction SilentlyContinue
}

# Migrate legacy 30-minute Scheduled Task to 1x Daily (silent via wscript.exe)
try {
    if (Get-Command Get-ScheduledTask -ErrorAction SilentlyContinue) {
        $existingTask = Get-ScheduledTask -TaskName "AntigravityOrchestratorAutoSync" -ErrorAction SilentlyContinue
        if ($existingTask -and $existingTask.Triggers -and $existingTask.Triggers[0].Repetition -and $existingTask.Triggers[0].Repetition.Interval -eq "PT30M") {
            $vbsLauncher = Join-Path $fleetLib "agy-silent-launch.vbs"
            $syncPs1 = Join-Path $localBin "agy-arch-sync.ps1"
            if (Test-Path $vbsLauncher) {
                $newAction = New-ScheduledTaskAction -Execute "wscript.exe" -Argument "//B //NoLogo `"$vbsLauncher`" powershell.exe -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$syncPs1`" -Quiet"
            } else {
                $newAction = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$syncPs1`" -Quiet"
            }
            $newTrigger = New-ScheduledTaskTrigger -Daily -At "04:00"
            $newSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
            Register-ScheduledTask -TaskName "AntigravityOrchestratorAutoSync" -Action $newAction -Trigger $newTrigger -Settings $newSettings -Force -ErrorAction SilentlyContinue | Out-Null
            Write-Log "   -> Migrated AntigravityOrchestratorAutoSync Scheduled Task from 30m to 1x Daily (silent)" "Green"
        }
    }
} catch {}

# 2. Sync registered workspaces
$syncScripts = @(
    "agy-hook.js",
    "gemini-budget.js",
    "codex-lib.sh",
    "frontier-orchestrate.sh",
    "codex-orchestrate.sh",
    "claude-orchestrate.sh",
    "opencode-orchestrate.sh",
    "codex-rca.sh",
    "gemini-quota-mode.sh",
    "preflight.sh"
)

if (Test-Path $wsRegistry) {
    try {
        $parsedReg = Read-JsonNoBom -Path $wsRegistry
        $workspaces = @()
        if ($parsedReg -is [System.Array]) {
            $workspaces = @($parsedReg | Where-Object { $_ })
        } elseif ($parsedReg -is [string] -and $parsedReg.Trim()) {
            $workspaces = @($parsedReg.Trim())
            # Self-heal legacy 1-element scalar JSON string into proper JSON array
            Write-Utf8NoBom -Path $wsRegistry -Content ((ConvertTo-Json -InputObject ([string[]]$workspaces)) + "`n")
        }
        foreach ($ws in $workspaces) {
            if ($ws -and (Test-Path $ws) -and (Test-Path (Join-Path $ws ".agents"))) {
                if (-not $Force -and (Test-Path (Join-Path $ws ".git"))) {
                    $dirty = git -C "$ws" status --porcelain -- .agents ':(exclude).agents/rules' ':(exclude).agent-state' ':(exclude).agent-reports' 2>$null
                    if ($dirty) {
                        Write-Log "   -> Skipping workspace $ws (uncommitted changes inside .agents/; pass -Force to override)" "DarkGray"
                        continue
                    }
                }
                Write-Log "   -> Syncing workspace: $ws" "DarkGray"
                $wsConfig = Join-Path $ws ".agents\config"
                $wsScripts = Join-Path $ws ".agents\scripts"
                New-Item -ItemType Directory -Path $wsConfig -Force | Out-Null
                New-Item -ItemType Directory -Path $wsScripts -Force | Out-Null

                # Refresh hooks.json if missing or using broken ./.agents/scripts/ prefix (skip silently if NTFS ACL-locked)
                $srcHooks = Join-Path $repoDir "workspace-template\.agents\hooks.json"
                $destHooks = Join-Path $ws ".agents\hooks.json"
                if (Test-Path $srcHooks) {
                    $needsHooksUpdate = -not (Test-Path $destHooks)
                    if (-not $needsHooksUpdate) {
                        try {
                            $curHooks = [System.IO.File]::ReadAllText($destHooks, [System.Text.Encoding]::UTF8)
                            if ($curHooks -like '*./.agents/scripts/*') { $needsHooksUpdate = $true }
                        } catch {}
                    }
                    if ($needsHooksUpdate) {
                        try { Copy-Item -Path $srcHooks -Destination $destHooks -Force -ErrorAction SilentlyContinue } catch {}
                    }
                }

                if (Test-Path $srcModelRouting) {
                    try { Copy-Item -Path $srcModelRouting -Destination (Join-Path $wsConfig "model-routing.json") -Force -ErrorAction SilentlyContinue } catch {}
                }

                foreach ($s in $syncScripts) {
                    $srcS = Join-Path $repoDir "workspace-template\.agents\scripts\$s"
                    if (Test-Path $srcS) {
                        try { Copy-Item -Path $srcS -Destination (Join-Path $wsScripts $s) -Force -ErrorAction SilentlyContinue } catch {}
                    }
                }

                # Sync workspace skills
                $srcWsSkills = Join-Path $repoDir "workspace-template\.agents\skills"
                if (Test-Path $srcWsSkills) {
                    $destWsSkills = Join-Path $ws ".agents\skills"
                    New-Item -ItemType Directory -Path $destWsSkills -Force | Out-Null
                    try { Copy-Item -Path "$srcWsSkills\*" -Destination $destWsSkills -Recurse -Force -ErrorAction SilentlyContinue } catch {}
                }

                # Sync workspace workflows
                $srcWsWorkflows = Join-Path $repoDir "workspace-template\.agents\workflows"
                if (Test-Path $srcWsWorkflows) {
                    $destWsWorkflows = Join-Path $ws ".agents\workflows"
                    New-Item -ItemType Directory -Path $destWsWorkflows -Force | Out-Null
                    try { Copy-Item -Path "$srcWsWorkflows\*" -Destination $destWsWorkflows -Recurse -Force -ErrorAction SilentlyContinue } catch {}
                }
            }
        }
    } catch {}
}

# 3. Stamp last sync time (epoch seconds)
$epoch = [int64]((Get-Date).ToUniversalTime() - (Get-Date "1970-01-01 00:00:00")).TotalSeconds
Write-Utf8NoBom -Path $stampFile -Content "$epoch`n"
Write-Log "✅ Architecture sync complete! Stamped $stampFile" "Green"
