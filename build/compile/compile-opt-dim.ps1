param(
    [Parameter(Mandatory = $true)]
    [string]$OptDim,

    [Parameter(Mandatory = $true)]
    [string]$WorkspaceRoot,

    [string]$FaSrc = "C:\fa\flash-attention",
    [string]$PythonExe = "python"
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $FaSrc)) {
    throw "flash-attention source not found: $FaSrc"
}

$shardOptDim = $OptDim

$BuildRoot = Join-Path $WorkspaceRoot "build"

. (Join-Path $BuildRoot "config\read-version-lock.ps1") -WorkspaceRoot $WorkspaceRoot

if ($shardOptDim -notin $OptDimList) {
    throw "OptDim '$shardOptDim' is not listed in VERSION.lock.json opt_dim: $($OptDimList -join ', ')"
}

. (Join-Path $BuildRoot "env\init-fa-build-env.ps1") `
    -WorkspaceRoot $WorkspaceRoot `
    -PythonExe $PythonExe `
    -OptDim $shardOptDim

Write-Host "Compiling OPT_DIM=$shardOptDim via in-process build_ext (same setuptools path as serial/link)"
Write-Host "Note: each shard also builds shared csrc/flash_attn_ck objs; link uses d$PRIMARY_OPT_DIM shard for shared objects only"

$wheelScript = Join-Path $BuildRoot "compile\link_parallel_wheel.py"
& $PythonExe $wheelScript --compile-only --fa-src $FaSrc -v
if ($LASTEXITCODE -ne 0) {
    throw "build_ext failed for OPT_DIM=$shardOptDim (exit $LASTEXITCODE)"
}

$releaseInfo = . (Join-Path $BuildRoot "common\get-fa-release-dir.ps1") `
    -FaSrc $FaSrc `
    -OptDim $shardOptDim `
    -PassThru
$releaseDir = $releaseInfo.ReleaseDir
Write-Host (
    "OPT_DIM=$shardOptDim produced $($releaseInfo.ObjCount) object files " +
    "($($releaseInfo.DimKernelCount) dim-kernel) under $releaseDir"
)

& $PythonExe $wheelScript `
    --validate-compile-shard `
    --release-dir $releaseDir `
    --opt-dim $shardOptDim
if ($LASTEXITCODE -ne 0) {
    throw "Compile shard validation failed for OPT_DIM=$shardOptDim (exit $LASTEXITCODE)"
}

$env:RELEASE_DIR = $releaseDir
if ($env:GITHUB_ENV) {
    "RELEASE_DIR=$releaseDir" | Out-File -FilePath $env:GITHUB_ENV -Append -Encoding utf8
}
