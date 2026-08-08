param(
    [Parameter(Mandatory = $true)]
    [string]$StagingRoot,

    [string]$PrimaryDim = "32"
)

$ErrorActionPreference = "Stop"

python (Join-Path $PSScriptRoot "link_parallel_wheel.py") `
    --validate-only `
    --staging-root $StagingRoot `
    --primary-dim $PrimaryDim

if ($LASTEXITCODE -ne 0) {
    throw "Link staging validation failed for $StagingRoot"
}
