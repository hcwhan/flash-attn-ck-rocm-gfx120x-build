param(
    [Parameter(Mandatory = $true)]
    [string]$PythonExe,

    [Parameter(Mandatory = $true)]
    [string]$WorkspaceRoot
)

$ErrorActionPreference = "Stop"

$BuildRoot = Join-Path $WorkspaceRoot "build"
. (Join-Path $BuildRoot "config\read-version-lock.ps1") -WorkspaceRoot $WorkspaceRoot

if (-not $env:OPT_DIM) {
    throw "OPT_DIM env must be set before setup-rocm-env.ps1"
}

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

print(f'CORE_ROOT={core_root}')
print(f'DEVEL_ROOT={devel_root}')
"@

$paths = & $PythonExe -c $pyCode
if ($LASTEXITCODE -ne 0) {
    throw "Failed to locate ROCm SDK paths via $PythonExe"
}

$coreRootLine = $paths | Where-Object { $_ -like 'CORE_ROOT=*' } | Select-Object -First 1
$develRootLine = $paths | Where-Object { $_ -like 'DEVEL_ROOT=*' } | Select-Object -First 1
if (-not $coreRootLine -or -not $develRootLine) {
    throw "Failed to parse ROCm SDK paths from $PythonExe output"
}
$coreRoot = $coreRootLine.Substring('CORE_ROOT='.Length)
$develRoot = $develRootLine.Substring('DEVEL_ROOT='.Length)
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
if ($env:CPATH) {
    $env:CPATH = "$hipInclude;$env:CPATH"
} else {
    $env:CPATH = $hipInclude
}
if ($env:INCLUDE) {
    $env:INCLUDE = "$hipInclude;$env:INCLUDE"
} else {
    $env:INCLUDE = $hipInclude
}
$env:PATH = "$llvmBin;$rocmBin;$env:PATH"
$env:CC = "clang-cl"
$env:CXX = "clang-cl"
$env:DISTUTILS_USE_SDK = "1"
$env:GPU_ARCHS = [string]$GPU_ARCHS
$env:FLASHATTENTION_DISABLE_BACKWARD = "TRUE"
$env:BUILD_TARGET = "rocm"

Write-Host "GPU_ARCHS=$env:GPU_ARCHS"
Write-Host "OPT_DIM=$env:OPT_DIM"
Write-Host "ROCM_HOME=$env:ROCM_HOME"

& $PythonExe -c "import torch; print('torch', torch.__version__); print('hip', torch.version.hip); print('abi', torch._C._GLIBCXX_USE_CXX11_ABI)"
