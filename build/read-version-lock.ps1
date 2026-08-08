param(
    [string]$WorkspaceRoot = "",

    [switch]$ExportToGitHubEnv
)

$ErrorActionPreference = "Stop"

if (-not $WorkspaceRoot) {
    $WorkspaceRoot = Split-Path $PSScriptRoot -Parent
}

$lockPath = Join-Path $WorkspaceRoot "VERSION.lock.json"
if (-not (Test-Path $lockPath)) {
    throw "VERSION.lock.json not found: $lockPath"
}

$lock = Get-Content $lockPath -Raw | ConvertFrom-Json

$vars = @{
    PYTHON_VERSION  = [string]$lock.python
    PYTORCH_VERSION = [string]$lock.pytorch
    TORCH_DEVICE    = [string]$lock.torch_device_extra
    ROCM_INDEX      = [string]$lock.rocm_index
    GPU_ARCHS       = [string]$lock.gpu_archs
    HIP_VERSION     = [string]$lock.hip
}

foreach ($name in $vars.Keys) {
    Set-Variable -Name $name -Value $vars[$name] -Scope Script
}

if ($ExportToGitHubEnv -and $env:GITHUB_ENV) {
    foreach ($name in $vars.Keys) {
        "${name}=$($vars[$name])" | Out-File -FilePath $env:GITHUB_ENV -Append -Encoding utf8
    }
    Write-Host "Exported VERSION.lock.json to GITHUB_ENV"
}

Write-Host "VERSION.lock: python=$($vars.PYTHON_VERSION) pytorch=$($vars.PYTORCH_VERSION) gpu=$($vars.GPU_ARCHS)"
