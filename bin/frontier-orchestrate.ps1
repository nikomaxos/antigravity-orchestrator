# =============================================================================
# Antigravity Frontier Orchestrator CLI (Windows PowerShell: `frontier-orchestrate.ps1`)
# =============================================================================
# Dispatches frontier reasoning tasks to the current repository's
# .agents/scripts/frontier-orchestrate.sh via Git Bash.
# =============================================================================
[CmdletBinding()]
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$ArgsList
)

$repoRoot = git rev-parse --show-toplevel 2>$null
if (-not $repoRoot) { $repoRoot = (Get-Location).Path }

$scriptPath = Join-Path $repoRoot ".agents\scripts\frontier-orchestrate.sh"
if (-not (Test-Path $scriptPath)) {
    $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
    $scriptPath = Join-Path $scriptDir "..\workspace-template\.agents\scripts\frontier-orchestrate.sh"
}

if (-not (Test-Path $scriptPath)) {
    Write-Error "frontier-orchestrate.sh not found."
    exit 1
}

# Find bash.exe (Git Bash)
$bashCmd = "bash"
$possibleBash = @(
    "bash",
    "$env:ProgramFiles\Git\bin\bash.exe",
    "${env:ProgramFiles(x86)}\Git\bin\bash.exe",
    "$env:LOCALAPPDATA\Programs\Git\bin\bash.exe"
)
foreach ($p in $possibleBash) {
    if ($p -eq "bash") {
        if (Get-Command bash -ErrorAction SilentlyContinue) { $bashCmd = "bash"; break }
    } elseif (Test-Path $p) {
        $bashCmd = $p
        break
    }
}

& $bashCmd $scriptPath @ArgsList
exit $LASTEXITCODE
