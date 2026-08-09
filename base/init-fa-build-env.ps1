param(
    [Parameter(Mandatory = $true)]
    [string]$WorkspaceRoot,

    [string]$PythonExe = "python",

    [string]$OptDim = ""
)

$ErrorActionPreference = "Stop"

& $PythonExe -m pip install numpy -q

if ($OptDim) {
    $env:OPT_DIM = $OptDim
}

if (-not $env:OPT_DIM) {
    throw "OPT_DIM env must be set before init-fa-build-env.ps1"
}

. (Join-Path $PSScriptRoot "read-version-lock.ps1") -WorkspaceRoot $WorkspaceRoot
. (Join-Path $PSScriptRoot "get-rocm-sdk-paths.ps1") -PythonExe $PythonExe

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
$env:SOURCE_DATE_EPOCH = [string]$SOURCE_DATE_EPOCH

Write-Host "SOURCE_DATE_EPOCH=$env:SOURCE_DATE_EPOCH (flash_attention_build_commit_date=$FLASH_ATTENTION_BUILD_COMMIT_DATE)"
Write-Host "GPU_ARCHS=$env:GPU_ARCHS"
Write-Host "OPT_DIM=$env:OPT_DIM"
Write-Host "ROCM_HOME=$env:ROCM_HOME"

& $PythonExe -c "import torch; print('torch', torch.__version__); print('hip', torch.version.hip); print('abi', torch._C._GLIBCXX_USE_CXX11_ABI)"

Write-Host "Build env ready (GPU_ARCHS=$env:GPU_ARCHS, OPT_DIM=$env:OPT_DIM)"
