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

. (Join-Path $WorkspaceRoot "build\read-version-lock.ps1") -WorkspaceRoot $WorkspaceRoot

if ($StagingRoot -and -not $PrimaryDim) {
    $PrimaryDim = $PrimaryOptDim
}

. (Join-Path $WorkspaceRoot "build\init-fa-build-env.ps1") `
    -WorkspaceRoot $WorkspaceRoot `
    -PythonExe $PythonExe

$wheelScript = Join-Path $WorkspaceRoot "build\link_parallel_wheel.py"
$wheelArgs = @(
    "--fa-src", $FaSrc,
    "--dist-dir", $DistDir,
    "--workspace-root", $WorkspaceRoot,
    "-v"
)

if ($StagingRoot) {
    if (-not $PrimaryDim) {
        throw "PrimaryDim is required when StagingRoot is set"
    }
    $wheelArgs += @(
        "--staging-root", $StagingRoot,
        "--primary-dim", $PrimaryDim
    )
} else {
    $wheelArgs += "--serial"
}

& $PythonExe $wheelScript @wheelArgs
if ($LASTEXITCODE -ne 0) {
    throw "bdist_wheel failed (exit $LASTEXITCODE)"
}
