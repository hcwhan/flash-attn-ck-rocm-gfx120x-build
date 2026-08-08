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

. (Join-Path $WorkspaceRoot "build\read-version-lock.ps1") -WorkspaceRoot $WorkspaceRoot

if ($shardOptDim -notin $OptDimList) {
    throw "OptDim '$shardOptDim' is not listed in VERSION.lock.json opt_dim: $($OptDimList -join ', ')"
}

. (Join-Path $WorkspaceRoot "build\init-fa-build-env.ps1") `
    -WorkspaceRoot $WorkspaceRoot `
    -PythonExe $PythonExe `
    -OptDim $shardOptDim

Write-Host "Compiling OPT_DIM=$shardOptDim via in-process build_ext (same setuptools path as serial/link)"
Write-Host "Note: each shard also builds shared csrc/flash_attn_ck objs; link uses d$PrimaryOptDim shard for shared objects only"

$wheelScript = Join-Path $WorkspaceRoot "build\link_parallel_wheel.py"
& $PythonExe $wheelScript --compile-only --fa-src $FaSrc -v
if ($LASTEXITCODE -ne 0) {
    throw "build_ext failed for OPT_DIM=$shardOptDim (exit $LASTEXITCODE)"
}

$tempRoot = Get-ChildItem -Path (Join-Path $FaSrc "build") -Directory -Filter "temp.win-*" |
    Select-Object -First 1
if (-not $tempRoot) {
    throw "No build/temp.win-* directory after build_ext"
}
$releaseDir = Join-Path $tempRoot.FullName "Release"
if (-not (Test-Path $releaseDir)) {
    throw "Release directory missing: $releaseDir"
}

$objCount = (Get-ChildItem $releaseDir -Recurse -Filter "*.obj").Count
Write-Host "OPT_DIM=$shardOptDim produced $objCount object files under $releaseDir"
if ($objCount -lt 1) {
    throw "No .obj files produced for OPT_DIM=$shardOptDim"
}
