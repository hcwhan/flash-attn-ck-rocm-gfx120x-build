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

. (Join-Path $WorkspaceRoot "build\setup-rocm-env.ps1") -PythonExe $PythonExe

Write-Host "Build env ready (OPT_DIM=$env:OPT_DIM)"
