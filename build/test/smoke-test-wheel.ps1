param(
    [Parameter(Mandatory = $true)]
    [string]$DistDir,

    [Parameter(Mandatory = $true)]
    [string]$WorkspaceRoot,

    [string]$PythonExe = "python"
)

$ErrorActionPreference = "Stop"

. (Join-Path (Split-Path $PSScriptRoot -Parent) "common\paths.ps1") -WorkspaceRoot $WorkspaceRoot -LoadVersionLock
$BuildRoot = $script:BuildRoot

$whls = @(Get-ChildItem (Join-Path $DistDir "*.whl") -File)
if ($whls.Count -ne 1) {
    throw "Expected exactly one wheel in $DistDir, found $($whls.Count)"
}
$whl = $whls[0]
if ($whl.Name -notlike $EXPECTED_WHEEL_PATTERN) {
    throw "Wheel name '$($whl.Name)' does not match expected pattern '$EXPECTED_WHEEL_PATTERN'"
}

Write-Host "Wheel name OK: $($whl.Name)"

$sha256Hex = (Get-FileHash -Path $whl.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
$checksumPath = Join-Path $DistDir "$($whl.Name).sha256"
"$sha256Hex  $($whl.Name)" | Set-Content -Path $checksumPath -Encoding ascii

$manifest = [ordered]@{
    wheel                        = $whl.Name
    sha256                       = $sha256Hex
    size_bytes                   = $whl.Length
    flash_attention_build_commit = $FLASH_ATTENTION_BUILD_COMMIT
    pytorch                      = $PYTORCH_VERSION
    python                       = $PYTHON_VERSION
    gpu_archs                    = $GPU_ARCHS
    opt_dim                      = $LockOptDim
}

Write-Host "Wheel SHA256: $sha256Hex"
Write-Host "Checksum file: $checksumPath"

& $PythonExe -m pip install --force-reinstall --no-deps $whl.FullName
if ($LASTEXITCODE -ne 0) {
    throw "pip install failed (exit $LASTEXITCODE)"
}

Write-Host "=== flash_attn extension ==="
& $PythonExe -c @"
import flash_attn
import flash_attn_2_cuda
from flash_attn import flash_attn_func

print('OK flash_attn', flash_attn.__file__)
print('OK flash_attn_2_cuda', flash_attn_2_cuda.__file__)
print('OK flash_attn_func', flash_attn_func)
"@
if ($LASTEXITCODE -ne 0) {
    throw "flash_attn extension import failed (exit $LASTEXITCODE)"
}

$manifestPath = Join-Path $DistDir "wheel.manifest.json"
$manifest | ConvertTo-Json -Depth 4 | Set-Content -Path $manifestPath -Encoding UTF8
Write-Host "Manifest file: $manifestPath"

Write-Host "CPU smoke test complete"
