param(
    [Parameter(Mandatory = $true)]
    [string]$FaSrc,

    [Parameter(Mandatory = $true)]
    [string]$DistDir,

    [Parameter(Mandatory = $true)]
    [string]$WorkspaceRoot,

    [string]$StagingRoot = "",

    [string]$PrimaryDim = "",

    [string]$PythonExe = "python"
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $FaSrc)) {
    throw "flash-attention source not found: $FaSrc"
}

$BuildRoot = Join-Path $WorkspaceRoot "build"
. (Join-Path $BuildRoot "config\read-version-lock.ps1") -WorkspaceRoot $WorkspaceRoot

if ($StagingRoot) {
    if (-not $PrimaryDim) {
        throw "PrimaryDim is required when StagingRoot is set"
    }
    $env:FLASH_ATTENTION_FORCE_BUILD = "FALSE"
} else {
    $env:FLASH_ATTENTION_FORCE_BUILD = "TRUE"
}

$env:OPT_DIM = [string]$LockOptDim

. (Join-Path $BuildRoot "env\init-fa-build-env.ps1") `
    -WorkspaceRoot $WorkspaceRoot `
    -PythonExe $PythonExe

$wheelScript = Join-Path $BuildRoot "compile\link_parallel_wheel.py"
$wheelArgs = @(
    "--fa-src", $FaSrc,
    "--dist-dir", $DistDir,
    "-v"
)

if ($StagingRoot) {
    $wheelArgs += @(
        "--staging-root", $StagingRoot,
        "--primary-dim", $PrimaryDim
    )
}

& $PythonExe $wheelScript @wheelArgs
if ($LASTEXITCODE -ne 0) {
    throw "bdist_wheel failed (exit $LASTEXITCODE)"
}
