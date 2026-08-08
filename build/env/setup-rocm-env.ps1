param(
    [Parameter(Mandatory = $true)]
    [string]$PythonExe,

    [Parameter(Mandatory = $true)]
    [string]$WorkspaceRoot
)

$ErrorActionPreference = "Stop"

$BuildRoot = Join-Path $WorkspaceRoot "build"
. (Join-Path $BuildRoot "config\read-version-lock.ps1") -WorkspaceRoot $WorkspaceRoot

$pyCode = @"
import importlib.util, os, subprocess, sys

spec = importlib.util.find_spec('_rocm_sdk_core')
if spec is None:
    raise SystemExit('ERROR: _rocm_sdk_core not found. Install torch[device-$($GPU_ARCHS)] first.')
core_root = os.path.dirname(spec.origin)

proc = subprocess.run(
    [sys.executable, '-m', 'rocm_sdk', 'path', '--root'],
    capture_output=True,
    text=True,
    check=True,
)
devel_root = proc.stdout.strip()
rocm_root = devel_root

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
$env:CPATH = $hipInclude
$env:INCLUDE = $hipInclude
$env:PATH = "$llvmBin;$rocmBin;$env:PATH"
$env:CC = "clang-cl"
$env:CXX = "clang-cl"
$env:DISTUTILS_USE_SDK = "1"
$env:GPU_ARCHS = [string]$GPU_ARCHS
if (-not $env:OPT_DIM) {
    $env:OPT_DIM = [string]$LockOptDim
}
$env:FLASHATTENTION_DISABLE_BACKWARD = "TRUE"
$env:BUILD_TARGET = "rocm"

Write-Host "GPU_ARCHS=$env:GPU_ARCHS"
Write-Host "OPT_DIM=$env:OPT_DIM"
Write-Host "ROCM_HOME=$env:ROCM_HOME"

& $PythonExe -c "import torch; print('torch', torch.__version__); print('hip', torch.version.hip); print('abi', torch._C._GLIBCXX_USE_CXX11_ABI)"
