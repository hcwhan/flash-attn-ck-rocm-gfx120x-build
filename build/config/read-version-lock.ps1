param(
    [Parameter(Mandatory = $true)]
    [string]$WorkspaceRoot,

    [switch]$ExportToGitHubEnv
)

$ErrorActionPreference = "Stop"

$lockPath = Join-Path $WorkspaceRoot "VERSION.lock.json"
if (-not (Test-Path $lockPath)) {
    throw "VERSION.lock.json not found: $lockPath"
}

$lock = Get-Content $lockPath -Raw | ConvertFrom-Json

$optDimString = [string]$lock.opt_dim
$optDimList = @(
    $optDimString -split "," |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ }
)
if ($optDimList.Count -lt 1) {
    throw "VERSION.lock.json opt_dim is missing or empty"
}

$expectedWheelPattern = [string]$lock.expected_wheel_pattern
if (-not $expectedWheelPattern) {
    throw "VERSION.lock.json expected_wheel_pattern is missing"
}

$wheelArtifactName = [string]$lock.wheel_artifact_name
if (-not $wheelArtifactName) {
    throw "VERSION.lock.json wheel_artifact_name is missing"
}

$flashAttentionRepo = [string]$lock.flash_attention_repo
$flashAttentionBuildCommit = [string]$lock.flash_attention_build_commit
if (-not $flashAttentionRepo) {
    throw "VERSION.lock.json flash_attention_repo is missing"
}
if (-not $flashAttentionBuildCommit) {
    throw "VERSION.lock.json flash_attention_build_commit is missing"
}

$vars = @{
    PYTHON_VERSION                = [string]$lock.python
    PYTORCH_VERSION               = [string]$lock.pytorch
    TORCH_DEVICE                  = [string]$lock.torch_device_extra
    ROCM_INDEX                    = [string]$lock.rocm_index
    GPU_ARCHS                     = [string]$lock.gpu_archs
    HIP_VERSION                   = [string]$lock.hip
    LockOptDim                    = $optDimString
    PRIMARY_OPT_DIM               = [string]$optDimList[0]
    WHEEL_ARTIFACT_NAME           = $wheelArtifactName
    EXPECTED_WHEEL_PATTERN        = $expectedWheelPattern
    FLASH_ATTENTION_REPO          = $flashAttentionRepo
    FLASH_ATTENTION_BUILD_COMMIT  = $flashAttentionBuildCommit
}

foreach ($name in $vars.Keys) {
    Set-Variable -Name $name -Value $vars[$name] -Scope Script
}
Set-Variable -Name OptDimList -Value $optDimList -Scope Script

if ($ExportToGitHubEnv -and $env:GITHUB_ENV) {
    foreach ($name in $vars.Keys) {
        "${name}=$($vars[$name])" | Out-File -FilePath $env:GITHUB_ENV -Append -Encoding utf8
    }
}

Write-Host "VERSION.lock: python=$($vars.PYTHON_VERSION) pytorch=$($vars.PYTORCH_VERSION) gpu=$($vars.GPU_ARCHS) opt_dim=$optDimString"
