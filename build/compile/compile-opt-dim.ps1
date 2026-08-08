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

$BuildRoot = Join-Path $WorkspaceRoot "build"
. (Join-Path $BuildRoot "config\read-version-lock.ps1") -WorkspaceRoot $WorkspaceRoot

if ($OptDim -notin $OptDimList) {
    throw "OptDim '$OptDim' is not listed in VERSION.lock.json opt_dim: $($OptDimList -join ', ')"
}

. (Join-Path $BuildRoot "env\init-fa-build-env.ps1") `
    -WorkspaceRoot $WorkspaceRoot `
    -PythonExe $PythonExe `
    -OptDim $OptDim

Write-Host "Compiling OPT_DIM=$OptDim via in-process build_ext"

$wheelScript = Join-Path $BuildRoot "compile\link_parallel_wheel.py"
& $PythonExe $wheelScript --compile-only --fa-src $FaSrc -v
if ($LASTEXITCODE -ne 0) {
    throw "build_ext failed for OPT_DIM=$OptDim (exit $LASTEXITCODE)"
}

$releaseInfo = . (Join-Path $BuildRoot "common\get-fa-release-dir.ps1") `
    -FaSrc $FaSrc `
    -OptDim $OptDim `
    -PassThru

Write-Host (
    "OPT_DIM=$OptDim produced $($releaseInfo.ObjCount) object files " +
    "($($releaseInfo.DimKernelCount) dim-kernel) under $($releaseInfo.ReleaseDir)"
)

$env:RELEASE_DIR = $releaseInfo.ReleaseDir
if ($env:GITHUB_ENV) {
    "RELEASE_DIR=$($releaseInfo.ReleaseDir)" | Out-File -FilePath $env:GITHUB_ENV -Append -Encoding utf8
}
