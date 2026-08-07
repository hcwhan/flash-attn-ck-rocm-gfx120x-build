param(
    [Parameter(Mandatory = $true)]
    [string]$PythonExe
)

$ErrorActionPreference = "Stop"

$pyCode = @"
import importlib.util, os, sys
spec = importlib.util.find_spec('_rocm_sdk_core')
if spec is None:
    raise SystemExit('ERROR: _rocm_sdk_core not found. Install torch[device-gfx1201] first.')
root = os.path.dirname(spec.origin)
print(root)
"@

$rocmRoot = & $PythonExe -c $pyCode
if ($LASTEXITCODE -ne 0) {
    throw "Failed to locate _rocm_sdk_core via $PythonExe"
}

$llvmBin = Join-Path $rocmRoot "lib\llvm\bin"
$rocmBin = Join-Path $rocmRoot "bin"
$deviceLibPath = Join-Path $rocmRoot "lib\llvm\amdgcn\bitcode"

$env:ROCM_HOME = $rocmRoot
$env:ROCM_PATH = $rocmRoot
$env:HIP_PATH = $rocmRoot
$env:HIP_DEVICE_LIB_PATH = $deviceLibPath
$env:DEVICE_LIB_PATH = $deviceLibPath
$env:PATH = "$llvmBin;$rocmBin;$env:PATH"
$env:CC = "clang-cl"
$env:CXX = "clang-cl"
$env:DISTUTILS_USE_SDK = "1"
$env:GPU_ARCHS = "gfx1201"
$env:OPT_DIM = "64,128,256"
$env:FLASHATTENTION_DISABLE_BACKWARD = "TRUE"
if (-not $env:MAX_JOBS) {
    $env:MAX_JOBS = "4"
}
$env:FLASH_ATTENTION_FORCE_BUILD = "TRUE"
$env:BUILD_TARGET = "rocm"

Write-Host "ROCM_HOME=$env:ROCM_HOME"
Write-Host "HIP_DEVICE_LIB_PATH=$env:HIP_DEVICE_LIB_PATH"
Write-Host "hipcc=$(Get-Command hipcc -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source)"
Write-Host "clang-cl=$(Get-Command clang-cl -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source)"

& $PythonExe -c "import torch; print('torch', torch.__version__); print('hip', torch.version.hip); print('abi', torch._C._GLIBCXX_USE_CXX11_ABI)"
