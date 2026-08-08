param(
    [string]$FaSrc = "C:\fa\flash-attention",

    [string]$DistDir = "",

    [string]$FlashAttentionRef = "main",

    [string]$MaxJobs = "4",

    [switch]$UseLockedCommit,

    [switch]$SkipPrep,

    [switch]$GpuSmokeTest,

    [string]$PythonExe = "python"
)

$ErrorActionPreference = "Stop"

$WorkspaceRoot = Split-Path $PSScriptRoot -Parent
if (-not $DistDir) {
    $DistDir = Join-Path $WorkspaceRoot "dist"
}

. (Join-Path $PSScriptRoot "read-version-lock.ps1") -WorkspaceRoot $WorkspaceRoot

$env:MAX_JOBS = $MaxJobs

if (-not $SkipPrep) {
    $prepParams = @{
        FlashAttentionRoot = $FaSrc
        FlashAttentionRef  = $FlashAttentionRef
        WorkspaceRoot      = $WorkspaceRoot
    }
    if ($UseLockedCommit) {
        $prepParams.UseLockedCommit = $true
    }
    . (Join-Path $PSScriptRoot "prep-flash-attention.ps1") @prepParams
}

New-Item -ItemType Directory -Force -Path $DistDir | Out-Null

. (Join-Path $PSScriptRoot "build-bdist-wheel.ps1") `
    -FaSrc $FaSrc `
    -DistDir $DistDir `
    -WorkspaceRoot $WorkspaceRoot `
    -PythonExe $PythonExe

. (Join-Path $PSScriptRoot "smoke-test-wheel.ps1") `
    -DistDir $DistDir `
    -WorkspaceRoot $WorkspaceRoot `
    -PythonExe $PythonExe

if ($GpuSmokeTest) {
    . (Join-Path $PSScriptRoot "gpu-smoke-test.ps1") -PythonExe $PythonExe
}

Write-Host "Local build complete. Wheel(s) in $DistDir"
