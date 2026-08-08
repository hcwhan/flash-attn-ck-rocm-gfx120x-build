param(
    [Parameter(Mandatory = $true)]
    [string]$FaSrc,

    [Parameter(Mandatory = $true)]
    [string]$DistDir,

    [Parameter(Mandatory = $true)]
    [string]$WorkspaceRoot,

    [string]$StagingRoot = "",

    [string]$PrimaryDim = "32"
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $FaSrc)) {
    throw "flash-attention source not found: $FaSrc"
}

& python -m pip install numpy -q
. (Join-Path $WorkspaceRoot "build\setup-rocm-env.ps1") -PythonExe python

$wheelScript = Join-Path $WorkspaceRoot "build\link_parallel_wheel.py"
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
} else {
    $wheelArgs += "--serial"
}

& python $wheelScript @wheelArgs
if ($LASTEXITCODE -ne 0) {
    throw "bdist_wheel failed (exit $LASTEXITCODE)"
}
