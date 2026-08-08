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

. (Join-Path $WorkspaceRoot "base\read-version-lock.ps1") -WorkspaceRoot $WorkspaceRoot

if ($StagingRoot) {
    if (-not $PrimaryDim) {
        throw "PrimaryDim is required when StagingRoot is set"
    }
}
# Always force a local build: with FLASH_ATTENTION_FORCE_BUILD=FALSE, FA's
# CachedWheelsCommand tries to download an upstream prebuilt wheel (whose name
# carries no GPU arch) and would silently bypass the merged objects on a hit.
$env:FLASH_ATTENTION_FORCE_BUILD = "TRUE"

$env:OPT_DIM = [string]$LockOptDim
# FA's get_package_version() only appends the +local tag when this env is set;
# without it the wheel name would not match expected_wheel_pattern.
$env:FLASH_ATTN_LOCAL_VERSION = $FLASH_ATTN_LOCAL_VERSION

. (Join-Path $WorkspaceRoot "base\init-fa-build-env.ps1") `
    -WorkspaceRoot $WorkspaceRoot `
    -PythonExe $PythonExe

$buildScript = Join-Path $WorkspaceRoot "base\build-fa-steps.py"

$step = if ($StagingRoot) { "merge-and-wheel" } else { "wheel" }

$buildArgs = @(
    "--step", $step,
    "--fa-src", $FaSrc,
    "--dist-dir", $DistDir,
    "-v"
)

if ($StagingRoot) {
    $buildArgs += @(
        "--staging-root", $StagingRoot,
        "--primary-dim", $PrimaryDim
    )
}

& $PythonExe $buildScript @buildArgs
if ($LASTEXITCODE -ne 0) {
    throw "bdist_wheel failed (exit $LASTEXITCODE)"
}
