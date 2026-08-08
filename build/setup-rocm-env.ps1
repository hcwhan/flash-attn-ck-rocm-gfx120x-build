param(
    [Parameter(Mandatory = $true)]
    [string]$PythonExe
)

$ErrorActionPreference = "Stop"

$pyCode = @"
import importlib.util, os, subprocess, sys

spec = importlib.util.find_spec('_rocm_sdk_core')
if spec is None:
    raise SystemExit('ERROR: _rocm_sdk_core not found. Install torch[device-gfx1201] first.')
core_root = os.path.dirname(spec.origin)

devel_root = None
try:
    proc = subprocess.run(
        [sys.executable, '-m', 'rocm_sdk', 'path', '--root'],
        capture_output=True,
        text=True,
        check=True,
    )
    devel_root = proc.stdout.strip()
except subprocess.CalledProcessError as exc:
    print(exc.stderr or exc.stdout, file=sys.stderr)
    raise SystemExit('ERROR: rocm[devel] not initialized. Run: python -m rocm_sdk init')

rocm_root = devel_root if devel_root else core_root
thrust_hdr = os.path.join(rocm_root, 'include', 'thrust', 'complex.h')
if not os.path.isfile(thrust_hdr):
    raise SystemExit(f'ERROR: thrust header missing: {thrust_hdr}')

print(core_root)
print(devel_root)
"@

$paths = & $PythonExe -c $pyCode
if ($LASTEXITCODE -ne 0) {
    throw "Failed to locate ROCm SDK paths via $PythonExe"
}

$coreRoot = $paths[0]
$develRoot = $paths[1]
$rocmRoot = $develRoot

$llvmBin = Join-Path $coreRoot "lib\llvm\bin"
$rocmBin = Join-Path $rocmRoot "bin"
$hipInclude = Join-Path $rocmRoot "include"
$deviceLibPath = Join-Path $coreRoot "lib\llvm\amdgcn\bitcode"

$env:ROCM_HOME = $rocmRoot
$env:ROCM_PATH = $rocmRoot
$env:HIP_PATH = $rocmRoot
$env:HIP_INCLUDE_PATH = $hipInclude
$env:HIP_DEVICE_LIB_PATH = $deviceLibPath
$env:DEVICE_LIB_PATH = $deviceLibPath
$env:CPATH = if ($env:CPATH) { "$hipInclude;$env:CPATH" } else { $hipInclude }
if ($env:INCLUDE) {
    $env:INCLUDE = "$hipInclude;$env:INCLUDE"
} else {
    $env:INCLUDE = $hipInclude
}
$env:PATH = "$llvmBin;$rocmBin;$env:PATH"
$env:CC = "clang-cl"
$env:CXX = "clang-cl"
$env:DISTUTILS_USE_SDK = "1"
$env:GPU_ARCHS = "gfx1201"
$env:OPT_DIM = "32,64,128,256"
$env:FLASHATTENTION_DISABLE_BACKWARD = "TRUE"
if (-not $env:MAX_JOBS) {
    $env:MAX_JOBS = "4"
}
$env:FLASH_ATTENTION_FORCE_BUILD = "TRUE"
$env:BUILD_TARGET = "rocm"

Write-Host "ROCM_HOME=$env:ROCM_HOME"
Write-Host "HIP_INCLUDE_PATH=$env:HIP_INCLUDE_PATH"
Write-Host "HIP_DEVICE_LIB_PATH=$env:HIP_DEVICE_LIB_PATH"
Write-Host "thrust=$hipInclude\thrust\complex.h"
Write-Host "hipcc=$(Get-Command hipcc -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source)"
Write-Host "clang-cl=$(Get-Command clang-cl -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source)"

& $PythonExe -c "import torch; print('torch', torch.__version__); print('hip', torch.version.hip); print('abi', torch._C._GLIBCXX_USE_CXX11_ABI)"
