# Read VERSION.lock.json into $script: variables. THE only script that reads
# the lock file directly. Dot-source only; all lock consumers (get-build-paths.ps1,
# init-fa-build-env.ps1, build scripts, actions) go through this entry.
param(
    [Parameter(Mandatory = $true)]
    [string]$WorkspaceRoot
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

$wheelLocalVersion = [string]$lock.wheel_local_version
if (-not $wheelLocalVersion) {
    throw "VERSION.lock.json wheel_local_version is missing"
}

$flashAttentionRepo = [string]$lock.flash_attention_repo
$flashAttentionBuildCommit = [string]$lock.flash_attention_build_commit
if (-not $flashAttentionRepo) {
    throw "VERSION.lock.json flash_attention_repo is missing"
}
if (-not $flashAttentionBuildCommit) {
    throw "VERSION.lock.json flash_attention_build_commit is missing"
}

$rawCommitDate = $lock.flash_attention_build_commit_date
if (-not $rawCommitDate) {
    throw "VERSION.lock.json flash_attention_build_commit_date is missing"
}
if ($rawCommitDate -is [DateTime]) {
    # ConvertFrom-Json parses ISO-8601 values as DateTime; normalize to UTC Z string.
    $commitDateOffset = [DateTimeOffset]::new($rawCommitDate.ToUniversalTime())
    $flashAttentionBuildCommitDate = $commitDateOffset.UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
} elseif ($rawCommitDate -is [string]) {
    $flashAttentionBuildCommitDate = $rawCommitDate.Trim()
    if (-not $flashAttentionBuildCommitDate) {
        throw "VERSION.lock.json flash_attention_build_commit_date is missing"
    }
    try {
        $commitDateOffset = [DateTimeOffset]::Parse(
            $flashAttentionBuildCommitDate,
            [Globalization.CultureInfo]::InvariantCulture
        )
    } catch {
        throw "VERSION.lock.json flash_attention_build_commit_date is not valid ISO 8601: $flashAttentionBuildCommitDate"
    }
    $flashAttentionBuildCommitDate = $commitDateOffset.UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
} else {
    throw "VERSION.lock.json flash_attention_build_commit_date has unsupported type: $($rawCommitDate.GetType().FullName)"
}
$sourceDateEpoch = [int64]$commitDateOffset.ToUnixTimeSeconds()
if ($sourceDateEpoch -lt 1) {
    throw "VERSION.lock.json flash_attention_build_commit_date must map to a positive Unix epoch"
}

# Remaining lock fields feed toolchain/CI directly; fail fast on empty values
# instead of letting them surface mid-pipeline (e.g. empty GPU_ARCHS).
foreach ($requiredField in @(
    'python', 'pytorch', 'hip', 'gpu_archs', 'rocm_index', 'torch_device_extra',
    'release_tag_prefix', 'release_name', 'release_prerelease'
)) {
    if (-not [string]$lock.$requiredField) {
        throw "VERSION.lock.json $requiredField is missing"
    }
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
    FLASH_ATTN_LOCAL_VERSION      = $wheelLocalVersion
    FLASH_ATTENTION_REPO              = $flashAttentionRepo
    FLASH_ATTENTION_BUILD_COMMIT      = $flashAttentionBuildCommit
    FLASH_ATTENTION_BUILD_COMMIT_DATE = $flashAttentionBuildCommitDate
    SOURCE_DATE_EPOCH                 = [string]$sourceDateEpoch
    RELEASE_TAG_PREFIX                = [string]$lock.release_tag_prefix
    RELEASE_NAME                  = [string]$lock.release_name
    RELEASE_PRERELEASE            = [string]$lock.release_prerelease
}

foreach ($name in $vars.Keys) {
    Set-Variable -Name $name -Value $vars[$name] -Scope Script
}
Set-Variable -Name OptDimList -Value $optDimList -Scope Script
# Exposed for adapters that export the values (e.g. 1.config -ExportToGitHubEnv).
Set-Variable -Name VersionLockVars -Value $vars -Scope Script

Write-Host "VERSION.lock: python=$($vars.PYTHON_VERSION) pytorch=$($vars.PYTORCH_VERSION) gpu=$($vars.GPU_ARCHS) opt_dim=$optDimString"
