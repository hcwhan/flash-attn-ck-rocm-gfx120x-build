param(
    [Parameter(Mandatory = $true)]
    [string]$OptDim,

    [Parameter(Mandatory = $true)]
    [string]$WorkspaceRoot,

    [Parameter(Mandatory = $true)]
    [string]$FaSrc,

    [string]$PythonExe = "python"
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $FaSrc)) {
    throw "flash-attention source not found: $FaSrc"
}

$BuildRoot = Join-Path $WorkspaceRoot "build"

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

$releaseDir = . (Join-Path $BuildRoot "common\get-fa-release-dir.ps1") `
    -FaSrc $FaSrc `
    -OptDim $OptDim

Write-Host "OPT_DIM=$OptDim release dir: $releaseDir"

$env:RELEASE_DIR = $releaseDir
if ($env:GITHUB_ENV) {
    "RELEASE_DIR=$releaseDir" | Out-File -FilePath $env:GITHUB_ENV -Append -Encoding utf8
}
