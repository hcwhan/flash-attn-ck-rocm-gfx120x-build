param(
    [Parameter(Mandatory = $true)]
    [string]$PythonExe,

    [Parameter(Mandatory = $true)]
    [string]$WorkspaceRoot
)

$ErrorActionPreference = "Stop"

if (-not $env:OPT_DIM) {
    throw "OPT_DIM env must be set before setup-rocm-env.ps1"
}

$BuildRoot = Join-Path $WorkspaceRoot "build"
. (Join-Path $BuildRoot "config\read-version-lock.ps1") -WorkspaceRoot $WorkspaceRoot
. (Join-Path $BuildRoot "common\get-rocm-sdk-paths.ps1") -PythonExe $PythonExe

$coreRoot = $script:CoreRoot
$rocmRoot = $script:DevelRoot

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
$env:BUILD_TARGET = "rocm"

Write-Host "GPU_ARCHS=$env:GPU_ARCHS"
Write-Host "OPT_DIM=$env:OPT_DIM"
Write-Host "ROCM_HOME=$env:ROCM_HOME"

& $PythonExe -c "import torch; print('torch', torch.__version__); print('hip', torch.version.hip); print('abi', torch._C._GLIBCXX_USE_CXX11_ABI)"
