param(
    [Parameter(Mandatory = $true)]
    [string]$StagingRoot,

    [string]$WorkspaceRoot = "",

    [string]$PrimaryDim = ""
)

# Manual/local CLI wrapper for link_parallel_wheel.py --validate-only.
# CI link jobs validate inside build/wheel/build-bdist-wheel.ps1 -> compile/link_parallel_wheel.py.

$ErrorActionPreference = "Stop"

. (Join-Path (Split-Path $PSScriptRoot -Parent) "common\paths.ps1") -WorkspaceRoot $WorkspaceRoot
$WorkspaceRoot = $script:WorkspaceRoot
$BuildRoot = $script:BuildRoot

. (Join-Path $BuildRoot "config\read-version-lock.ps1") -WorkspaceRoot $WorkspaceRoot

if (-not $PrimaryDim) {
    $PrimaryDim = $PrimaryOptDim
}

$env:OPT_DIM = $LockOptDim

python (Join-Path $BuildRoot "compile\link_parallel_wheel.py") `
    --validate-only `
    --staging-root $StagingRoot `
    --workspace-root $WorkspaceRoot `
    --primary-dim $PrimaryDim

if ($LASTEXITCODE -ne 0) {
    throw "Link staging validation failed for $StagingRoot"
}
