param(
    [Parameter(Mandatory = $true)]
    [string]$DistDir,

    [string]$WorkspaceRoot = "",

    [string]$FaCommitSha = "",

    [string]$FaSrc = "",

    [string]$PythonExe = "python"
)

$ErrorActionPreference = "Stop"

. (Join-Path (Split-Path $PSScriptRoot -Parent) "common\paths.ps1") -WorkspaceRoot $WorkspaceRoot
$WorkspaceRoot = $script:WorkspaceRoot
$BuildRoot = $script:BuildRoot

. (Join-Path $BuildRoot "common\git-sha.ps1")
. (Join-Path $BuildRoot "config\wheel-pattern.ps1")

$skipExtensionImport = ($env:FA_SKIP_EXTENSION_IMPORT -eq "1")
$smokeReport = [ordered]@{
    wheel_structure = "pending"
    pip_install     = "pending"
    extension_import = if ($skipExtensionImport) { "skipped" } else { "pending" }
    cuda_available  = $null
    cxx11_abi       = $null
    extension_origin = ""
    public_symbol_count = 0
    dumpbin_checked = $false
    dumpbin_hip_dll = $false
}

function Invoke-PythonCheck {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Label,

        [Parameter(Mandatory = $true)]
        [string]$Code
    )

    Write-Host "=== $Label ==="
    & $PythonExe -c $Code
    if ($LASTEXITCODE -ne 0) {
        throw "${Label} failed (exit $LASTEXITCODE)"
    }
}

function Write-SmokeStepSummary {
    param(
        [hashtable]$Report,
        [string]$WheelName
    )

    if (-not $env:GITHUB_STEP_SUMMARY) {
        return
    }

    $cuda = if ($null -eq $Report.cuda_available) { "n/a" } else { [string]$Report.cuda_available }
    $lines = @(
        "## CPU smoke test",
        "",
        "| Check | Result |",
        "|-------|--------|",
        "| Wheel | ``$WheelName`` |",
        "| Wheel structure (.pyd in archive) | $($Report.wheel_structure) |",
        "| pip install | $($Report.pip_install) |",
        "| Extension import (L3) | $($Report.extension_import) |",
        "| ``torch.cuda.is_available()`` | $cuda |",
        "| ``_GLIBCXX_USE_CXX11_ABI`` | $(if ($null -eq $Report.cxx11_abi) { 'n/a' } else { [string]$Report.cxx11_abi }) |",
        "| Extension path | $($Report.extension_origin) |",
        "| Public symbol count | $($Report.public_symbol_count) |",
        "| dumpbin HIP DLL deps | $(if ($Report.dumpbin_checked) { [string]$Report.dumpbin_hip_dll } else { 'skipped' }) |",
        "",
        "> L3 pass on hosted runner confirms extension **load** only, not gfx1201 kernel correctness. Run ``gpu-smoke-test.ps1`` on GPU before deploy."
    )
    if ($skipExtensionImport) {
        $lines += "> ``FA_SKIP_EXTENSION_IMPORT=1``: extension import checks were skipped."
    }
    ($lines -join "`n") | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Append -Encoding utf8
}

if (-not $FaCommitSha -and $FaSrc) {
    $metaPath = Join-Path $FaSrc ".fa-build-meta.json"
    if (Test-Path $metaPath) {
        $meta = Get-Content $metaPath -Raw | ConvertFrom-Json
        if ($meta.flash_attention_commit) {
            $FaCommitSha = [string]$meta.flash_attention_commit
            Write-Host "Resolved flash-attention commit from ${metaPath}: $FaCommitSha"
        }
    }
}

$lockPath = Join-Path $WorkspaceRoot "VERSION.lock.json"
$expectedPattern = "flash_attn-*.whl"
$lock = $null
if (Test-Path $lockPath) {
    $lock = Get-Content $lockPath -Raw | ConvertFrom-Json
    $expectedPattern = Assert-ExpectedWheelPatternConsistent -Lock $lock -PythonExe $PythonExe
}

if ($FaCommitSha -and $lock -and $lock.flash_attention_build_commit) {
    $buildCommit = [string]$lock.flash_attention_build_commit
    $repoRoot = if ($FaSrc -and (Test-Path (Join-Path $FaSrc ".git"))) { $FaSrc } else { "" }
    if (-not (Test-GitShaEqual -Left $FaCommitSha -Right $buildCommit -RepoRoot $repoRoot)) {
        throw "FaCommitSha '$FaCommitSha' does not match VERSION.lock.json flash_attention_build_commit '$buildCommit'"
    }
}

$whl = Get-ChildItem (Join-Path $DistDir "*.whl") | Select-Object -First 1
if (-not $whl) {
    throw "No wheel produced in $DistDir"
}

if ($whl.Name -notlike $expectedPattern) {
    throw "Wheel name '$($whl.Name)' does not match expected pattern '$expectedPattern'"
}

Write-Host "Wheel name OK: $($whl.Name)"

$hash = Get-FileHash -Path $whl.FullName -Algorithm SHA256
$sha256Hex = $hash.Hash.ToLowerInvariant()

$checksumPath = Join-Path $DistDir "$($whl.Name).sha256"
"$sha256Hex  $($whl.Name)" | Set-Content -Path $checksumPath -Encoding ascii

$verifyHex = (Get-FileHash -Path $whl.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
if ($verifyHex -ne $sha256Hex) {
    throw "Wheel SHA256 verification failed for $($whl.Name)"
}

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
$smokeReport.wheel_structure = "pass"

$manifest = [ordered]@{
    wheel      = $whl.Name
    sha256     = $sha256Hex
    size_bytes = $whl.Length
}
if ($FaCommitSha) {
    $manifest.flash_attention_commit = $FaCommitSha
}
if ($lock) {
    if ($lock.flash_attention_build_commit) {
        $manifest.flash_attention_build_commit = [string]$lock.flash_attention_build_commit
    }
    if ($lock.flash_attention_min_commit) {
        $manifest.flash_attention_min_commit = [string]$lock.flash_attention_min_commit
    }
    if ($lock.pytorch) {
        $manifest.pytorch = [string]$lock.pytorch
    }
    if ($lock.python) {
        $manifest.python = [string]$lock.python
    }
    if ($lock.gpu_archs) {
        $manifest.gpu_archs = [string]$lock.gpu_archs
    }
    if ($lock.opt_dim) {
        $manifest.opt_dim = [string]$lock.opt_dim
    }
}

$manifestPath = Join-Path $DistDir "wheel.manifest.json"

Write-Host "Wheel SHA256: $sha256Hex"
Write-Host "Checksum file: $checksumPath"
Write-Host "CPU smoke test: layered checks (structure -> pip -> optional extension import)"

& $PythonExe -m pip install --force-reinstall --no-deps $whl.FullName
if ($LASTEXITCODE -ne 0) {
    throw "pip install failed (exit $LASTEXITCODE)"
}
$smokeReport.pip_install = "pass"

if (-not $skipExtensionImport) {
    Write-Host "=== torch runtime ==="
    $torchRuntimeOutput = & $PythonExe -c @"
import torch
abi = torch._C._GLIBCXX_USE_CXX11_ABI
cuda = torch.cuda.is_available()
print('torch', torch.__version__)
print('hip', torch.version.hip)
print('CXX11_ABI', abi)
print('CUDA_AVAILABLE', cuda)
if not abi:
    raise SystemExit('ERROR: _GLIBCXX_USE_CXX11_ABI is False; wheel requires cxx11abiTRUE')
"@
    if ($LASTEXITCODE -ne 0) {
        throw "torch runtime failed (exit $LASTEXITCODE)"
    }
    $torchRuntimeOutput | ForEach-Object { Write-Host $_ }

    $cxx11Line = $torchRuntimeOutput | Where-Object { $_ -like "CXX11_ABI *" } | Select-Object -First 1
    if ($cxx11Line -match "CXX11_ABI\s+(True|False)") {
        $smokeReport.cxx11_abi = ($Matches[1] -eq "True")
    }
    if (-not $smokeReport.cxx11_abi) {
        throw "torch._C._GLIBCXX_USE_CXX11_ABI is False; expected cxx11abiTRUE build"
    }

    $cudaLine = $torchRuntimeOutput | Where-Object { $_ -like "CUDA_AVAILABLE *" } | Select-Object -First 1
    if ($cudaLine -match "CUDA_AVAILABLE\s+(True|False)") {
        $smokeReport.cuda_available = ($Matches[1] -eq "True")
    }
    Write-Host "torch.cuda.is_available() = $($smokeReport.cuda_available)"

    Invoke-PythonCheck -Label "flash_attn python package" -Code "import flash_attn; print('OK', flash_attn.__file__)"

    $extensionOrigin = (& $PythonExe -c @"
import importlib.util
spec = importlib.util.find_spec('flash_attn_2_cuda')
if spec is None or not spec.origin:
    raise SystemExit('ERROR: flash_attn_2_cuda spec/origin missing')
print(spec.origin)
"@).Trim()
    if ($LASTEXITCODE -ne 0) {
        throw "flash_attn_2_cuda find_spec failed (exit $LASTEXITCODE)"
    }
    $smokeReport.extension_origin = $extensionOrigin
    Write-Host "flash_attn_2_cuda origin: $extensionOrigin"

    Invoke-PythonCheck -Label "flash_attn_2_cuda extension load" -Code "import flash_attn_2_cuda; print('OK', flash_attn_2_cuda.__file__)"

    $symbolInfo = & $PythonExe -c @"
import flash_attn_2_cuda
public = [name for name in dir(flash_attn_2_cuda) if not name.startswith('_')]
print('symbol_count', len(public))
print('symbols', public[:20])
if len(public) < 1:
    raise SystemExit('ERROR: flash_attn_2_cuda has no public symbols')
"@
    if ($LASTEXITCODE -ne 0) {
        throw "flash_attn_2_cuda symbol check failed (exit $LASTEXITCODE)"
    }
    $symbolCountLine = $symbolInfo | Where-Object { $_ -like "symbol_count *" } | Select-Object -First 1
    if ($symbolCountLine -match "symbol_count\s+(\d+)") {
        $smokeReport.public_symbol_count = [int]$Matches[1]
    }
    $symbolInfo | ForEach-Object { Write-Host $_ }

    Invoke-PythonCheck -Label "flash_attn_func import" -Code "from flash_attn import flash_attn_func; print('OK', flash_attn_func)"

    $dumpbin = Get-Command dumpbin -ErrorAction SilentlyContinue
    if ($dumpbin -and $extensionOrigin -and (Test-Path $extensionOrigin)) {
        Write-Host "=== dumpbin /DEPENDENTS (extension DLL chain) ==="
        $depOutput = & dumpbin /DEPENDENTS $extensionOrigin 2>&1 | ForEach-Object { "$_" }
        $depText = $depOutput -join "`n"
        $depOutput | ForEach-Object { Write-Host $_ }
        $smokeReport.dumpbin_checked = $true
        $smokeReport.dumpbin_hip_dll = ($depText -match '(?i)(amdhip|hip(?:64)?|rocblas|torch|hsa-runtime)')
        if (-not $smokeReport.dumpbin_hip_dll) {
            $dumpbinMsg = "dumpbin /DEPENDENTS did not list expected HIP/torch dependencies; review output above"
            if ($env:FA_STRICT_DUMPBIN -eq "1") {
                throw $dumpbinMsg
            }
            Write-Warning $dumpbinMsg
        }
    } else {
        Write-Host "dumpbin not available or extension path missing; skipping DLL dependency listing"
    }

    $smokeReport.extension_import = "pass"
} else {
    Write-Host "FA_SKIP_EXTENSION_IMPORT=1: skipping torch import, extension load, and dumpbin checks"
    Invoke-PythonCheck -Label "pip-installed flash_attn package path" -Code @"
import importlib.util
spec = importlib.util.find_spec('flash_attn')
if spec is None or not spec.origin:
    raise SystemExit('ERROR: flash_attn package not found after pip install')
print('OK', spec.origin)
"@
}

$manifest.smoke_test = [ordered]@{
    wheel_structure     = [string]$smokeReport.wheel_structure
    pip_install         = [string]$smokeReport.pip_install
    extension_import    = [string]$smokeReport.extension_import
    cuda_available      = $smokeReport.cuda_available
    cxx11_abi           = $smokeReport.cxx11_abi
    extension_origin    = [string]$smokeReport.extension_origin
    public_symbol_count = $smokeReport.public_symbol_count
    dumpbin_checked     = [bool]$smokeReport.dumpbin_checked
    dumpbin_hip_dll     = [bool]$smokeReport.dumpbin_hip_dll
    skip_extension_import = $skipExtensionImport
}

$manifest | ConvertTo-Json -Depth 4 | Set-Content -Path $manifestPath -Encoding UTF8
Write-Host "Manifest file: $manifestPath"

if ($FaCommitSha) {
    $manifestRead = Get-Content $manifestPath -Raw | ConvertFrom-Json
    $manifestCommit = [string]$manifestRead.flash_attention_commit
    $repoRoot = if ($FaSrc -and (Test-Path (Join-Path $FaSrc ".git"))) { $FaSrc } else { "" }
    if (-not (Test-GitShaEqual -Left $manifestCommit -Right $FaCommitSha -RepoRoot $repoRoot)) {
        throw "wheel.manifest.json flash_attention_commit '$manifestCommit' does not match expected '$FaCommitSha'"
    }
    Write-Host "Manifest flash_attention_commit OK: $FaCommitSha"
}

Write-SmokeStepSummary -Report $smokeReport -WheelName $whl.Name
Write-Host "CPU smoke test complete"
