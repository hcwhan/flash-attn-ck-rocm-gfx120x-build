param(
    [Parameter(Mandatory = $true)]
    [string]$StagingRoot,

    [string]$WorkspaceRoot = "",

    [string]$PrimaryDim = ""
)

# Manual/local CLI wrapper for link_parallel_wheel.py --validate-only.
# CI link jobs validate inside build-bdist-wheel.ps1 -> link_parallel_wheel.py.

$ErrorActionPreference = "Stop"

if (-not $WorkspaceRoot) {
    $WorkspaceRoot = Split-Path $PSScriptRoot -Parent
}

. (Join-Path $WorkspaceRoot "build\read-version-lock.ps1") -WorkspaceRoot $WorkspaceRoot

if (-not $PrimaryDim) {
    $PrimaryDim = $PrimaryOptDim
}

$env:OPT_DIM = $LockOptDim

python (Join-Path $PSScriptRoot "link_parallel_wheel.py") `
    --validate-only `
    --staging-root $StagingRoot `
    --workspace-root $WorkspaceRoot `
    --primary-dim $PrimaryDim

if ($LASTEXITCODE -ne 0) {
    throw "Link staging validation failed for $StagingRoot"
}
