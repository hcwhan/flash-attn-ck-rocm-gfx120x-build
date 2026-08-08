param(
    [Parameter(Mandatory = $true)]
    [string]$DistDir,

    [Parameter(Mandatory = $true)]
    [string]$WorkspaceRoot,

    [string]$PythonExe = "python"
)

$ErrorActionPreference = "Stop"

. (Join-Path (Split-Path $PSScriptRoot -Parent) "common\paths.ps1") -WorkspaceRoot $WorkspaceRoot
$BuildRoot = $script:BuildRoot

. (Join-Path $BuildRoot "config\read-version-lock.ps1") -WorkspaceRoot $WorkspaceRoot

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

Write-Host "=== Wheel structure (pre-install) ==="
$wheelInspectCode = @"
import sys, zipfile
wheel = sys.argv[1]
min_pyd_bytes = 1024
with zipfile.ZipFile(wheel) as zf:
    pyds = [
        name for name in zf.namelist()
        if name.endswith('.pyd') and 'flash_attn_2_cuda' in name.replace('\\\\', '/')
    ]
    if not pyds:
        raise SystemExit('ERROR: flash_attn_2_cuda .pyd not found in wheel archive')
    for name in pyds:
        info = zf.getinfo(name)
        if info.file_size < min_pyd_bytes:
            raise SystemExit(f'ERROR: {name} too small ({info.file_size} bytes)')
        print(f'OK {name} size={info.file_size}')
"@
& $PythonExe -c $wheelInspectCode $whl.FullName
if ($LASTEXITCODE -ne 0) {
    throw "Wheel structure check failed (exit $LASTEXITCODE)"
}

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

Write-Host "=== torch runtime ==="
& $PythonExe -c @"
import torch
if not torch._C._GLIBCXX_USE_CXX11_ABI:
    raise SystemExit('ERROR: _GLIBCXX_USE_CXX11_ABI is False; wheel requires cxx11abiTRUE')
print('torch', torch.__version__)
print('hip', torch.version.hip)
print('CXX11_ABI', torch._C._GLIBCXX_USE_CXX11_ABI)
"@
if ($LASTEXITCODE -ne 0) {
    throw "torch runtime failed (exit $LASTEXITCODE)"
}

Write-Host "=== flash_attn extension ==="
& $PythonExe -c @"
import importlib.util
import flash_attn
import flash_attn_2_cuda
from flash_attn import flash_attn_func

spec = importlib.util.find_spec('flash_attn_2_cuda')
if spec is None or not spec.origin:
    raise SystemExit('ERROR: flash_attn_2_cuda spec/origin missing')
public = [name for name in dir(flash_attn_2_cuda) if not name.startswith('_')]
if len(public) < 1:
    raise SystemExit('ERROR: flash_attn_2_cuda has no public symbols')
print('OK flash_attn', flash_attn.__file__)
print('OK flash_attn_2_cuda', spec.origin)
print('symbol_count', len(public))
print('OK flash_attn_func', flash_attn_func)
"@
if ($LASTEXITCODE -ne 0) {
    throw "flash_attn extension import failed (exit $LASTEXITCODE)"
}

$manifestPath = Join-Path $DistDir "wheel.manifest.json"
$manifest | ConvertTo-Json -Depth 4 | Set-Content -Path $manifestPath -Encoding UTF8
Write-Host "Manifest file: $manifestPath"

if ($env:GITHUB_STEP_SUMMARY) {
    @(
        "## CPU smoke test",
        "",
        "| Check | Result |",
        "|-------|--------|",
        "| Wheel | ``$($whl.Name)`` |",
        "| Wheel structure | pass |",
        "| pip install | pass |",
        "| Extension import | pass |",
        "",
        "> Run ``gpu-smoke-test.ps1`` on gfx1201 GPU before deploy."
    ) -join "`n" | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Append -Encoding utf8
}

Write-Host "CPU smoke test complete"
