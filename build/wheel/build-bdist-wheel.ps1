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

if ($StagingRoot -and -not $PrimaryDim) {
    if ($PRIMARY_OPT_DIM) {
        $PrimaryDim = $PRIMARY_OPT_DIM
    } elseif ($env:PRIMARY_OPT_DIM) {
        $PrimaryDim = $env:PRIMARY_OPT_DIM
    }
}

if ($StagingRoot) {
    # Prebuilt .obj merge during link relies on ninja incremental skip; FORCE_BUILD would rebuild all.
    $env:FLASH_ATTENTION_FORCE_BUILD = "FALSE"
    Write-Host "Parallel link: FLASH_ATTENTION_FORCE_BUILD=FALSE (preserve prebuilt .obj merge)"
}

. (Join-Path $BuildRoot "env\init-fa-build-env.ps1") `
    -WorkspaceRoot $WorkspaceRoot `
    -PythonExe $PythonExe

$wheelScript = Join-Path $BuildRoot "compile\link_parallel_wheel.py"
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
