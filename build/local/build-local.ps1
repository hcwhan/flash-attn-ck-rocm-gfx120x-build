param(
    [string]$FaSrc = "C:\fa\flash-attention",

    [string]$DistDir = "",

    [string]$NinjaWorkers = "4",

    [switch]$GpuSmokeTest,

    [string]$PythonExe = "python"
)

$ErrorActionPreference = "Stop"

. (Join-Path (Split-Path $PSScriptRoot -Parent) "common\paths.ps1")
$BuildRoot = $script:BuildRoot
$WorkspaceRoot = $script:WorkspaceRoot

if (-not $DistDir) {
    $DistDir = Join-Path $WorkspaceRoot "dist"
}

. (Join-Path $BuildRoot "config\read-version-lock.ps1") -WorkspaceRoot $WorkspaceRoot

$env:MAX_JOBS = $NinjaWorkers

. (Join-Path $BuildRoot "prep\prep-flash-attention.ps1") `
    -FlashAttentionRoot $FaSrc `
    -WorkspaceRoot $WorkspaceRoot

New-Item -ItemType Directory -Force -Path $DistDir | Out-Null

. (Join-Path $BuildRoot "wheel\build-bdist-wheel.ps1") `
    -FaSrc $FaSrc `
    -DistDir $DistDir `
    -WorkspaceRoot $WorkspaceRoot `
    -PythonExe $PythonExe

. (Join-Path $BuildRoot "test\smoke-test-wheel.ps1") `
    -DistDir $DistDir `
    -WorkspaceRoot $WorkspaceRoot `
    -PythonExe $PythonExe

if ($GpuSmokeTest) {
    . (Join-Path $BuildRoot "test\gpu-smoke-test.ps1") `
        -PythonExe $PythonExe `
        -WorkspaceRoot $WorkspaceRoot
}

Write-Host "Local build complete. Wheel(s) in $DistDir"
