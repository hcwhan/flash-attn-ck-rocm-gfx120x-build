param(
    [string]$FaSrc = "C:\fa\flash-attention",

    [string]$DistDir = "",

    [string]$NinjaWorkers = "4",

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

$env:MAX_JOBS = $NinjaWorkers

if (-not $SkipPrep) {
    . (Join-Path $PSScriptRoot "prep-flash-attention.ps1") `
        -FlashAttentionRoot $FaSrc `
        -WorkspaceRoot $WorkspaceRoot
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
    -FaSrc $FaSrc `
    -PythonExe $PythonExe

if ($GpuSmokeTest) {
    . (Join-Path $PSScriptRoot "gpu-smoke-test.ps1") -PythonExe $PythonExe
}

Write-Host "Local build complete. Wheel(s) in $DistDir"
