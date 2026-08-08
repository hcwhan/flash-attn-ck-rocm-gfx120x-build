param(
    [Parameter(Mandatory = $true)]
    [string]$WorkspaceRoot,

    [string]$PythonExe = "python",

    [string]$OptDim = ""
)

$ErrorActionPreference = "Stop"

& $PythonExe -m pip install numpy -q

if ($OptDim) {
    $env:OPT_DIM = $OptDim
}

. (Join-Path $WorkspaceRoot "build\setup-rocm-env.ps1") `
    -PythonExe $PythonExe `
    -WorkspaceRoot $WorkspaceRoot

Write-Host "Build env ready (GPU_ARCHS=$env:GPU_ARCHS, OPT_DIM=$env:OPT_DIM)"
