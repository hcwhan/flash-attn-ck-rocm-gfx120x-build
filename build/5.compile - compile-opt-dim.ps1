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

. (Join-Path $WorkspaceRoot "base\init-fa-build-env.ps1") `
    -WorkspaceRoot $WorkspaceRoot `
    -PythonExe $PythonExe `
    -OptDim $OptDim

Write-Host "Compiling OPT_DIM=$OptDim via in-process build_ext"

$buildScript = Join-Path $WorkspaceRoot "base\build-fa-steps.py"
& $PythonExe $buildScript --step compile --fa-src $FaSrc -v
if ($LASTEXITCODE -ne 0) {
    throw "build_ext failed for OPT_DIM=$OptDim (exit $LASTEXITCODE)"
}

Write-Host "Compile done for OPT_DIM=$OptDim"
