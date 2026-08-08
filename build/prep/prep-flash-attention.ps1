param(
    [Parameter(Mandatory = $true)]
    [string]$FlashAttentionRoot,

    [Parameter(Mandatory = $true)]
    [string]$WorkspaceRoot
)

$ErrorActionPreference = "Stop"

$lockPath = Join-Path $WorkspaceRoot "VERSION.lock.json"
if (-not (Test-Path $lockPath)) {
    throw "VERSION.lock.json not found: $lockPath"
}

$lock = Get-Content $lockPath -Raw | ConvertFrom-Json

$repoUrl = [string]$lock.flash_attention_repo
$buildCommit = [string]$lock.flash_attention_build_commit
$minCommit = [string]$lock.flash_attention_min_commit

if (-not $repoUrl) {
    throw "VERSION.lock.json flash_attention_repo is missing"
}
if (-not $buildCommit) {
    throw "VERSION.lock.json flash_attention_build_commit is missing"
}
if (-not $minCommit) {
    throw "VERSION.lock.json flash_attention_min_commit is missing"
}

Write-Host "Using flash-attention repo from VERSION.lock.json: $repoUrl"
Write-Host "Using flash-attention build commit: $buildCommit"
Write-Host "flash_attention min commit (build must not be earlier): $minCommit"

function Test-IsGitCommitRef {
    param([string]$Ref)
    return $Ref -match '^[0-9a-fA-F]{7,40}$'
}

function Assert-GitCommitRef {
    param(
        [string]$Name,
        [string]$Ref
    )

    if (-not (Test-IsGitCommitRef $Ref)) {
        throw "VERSION.lock.json $Name must be a git commit SHA, got: $Ref"
    }
}

Assert-GitCommitRef -Name "flash_attention_build_commit" -Ref $buildCommit
Assert-GitCommitRef -Name "flash_attention_min_commit" -Ref $minCommit

function Initialize-FlashAttentionRepo {
    param(
        [string]$Root,
        [string]$Repo,
        [string]$Ref
    )

    $parent = Split-Path -Parent $Root
    if (-not (Test-Path $parent)) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }
    if (Test-Path $Root) {
        Remove-Item -Recurse -Force $Root
    }

    Write-Host "Cloning flash-attention at commit $Ref"
    git -c core.longpaths=true clone --filter=blob:none --no-checkout $Repo $Root
    git -c core.longpaths=true -C $Root fetch --depth 1 origin $Ref
    git -C $Root checkout FETCH_HEAD
}

function Assert-BuildCommitMeetsMin {
    param(
        [string]$Root,
        [string]$BuildCommit,
        [string]$MinCommit
    )

    $head = (git -C $Root rev-parse HEAD).Trim()
    if (-not ($head.StartsWith($BuildCommit) -or $BuildCommit.StartsWith($head))) {
        throw "Resolved flash-attention commit ($head) does not match flash_attention_build_commit ($BuildCommit)"
    }

    if ($head.StartsWith($MinCommit) -or $MinCommit.StartsWith($head)) {
        Write-Host "Verified build commit $head meets flash_attention_min_commit $MinCommit"
        return
    }

    git -c core.longpaths=true -C $Root fetch --depth 1 origin $MinCommit
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to fetch flash_attention_min_commit $MinCommit"
    }

    git -C $Root merge-base --is-ancestor $MinCommit HEAD
    if ($LASTEXITCODE -ne 0) {
        # depth-1 clone/fetch leaves min and build commits disconnected; deepen before re-check
        Write-Host "Shallow clone lacks ancestry link; deepening fetch for min-commit check..."
        git -c core.longpaths=true -C $Root fetch --deepen=2000 origin
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to deepen flash-attention clone for min-commit ancestry check"
        }

        git -C $Root merge-base --is-ancestor $MinCommit HEAD
        if ($LASTEXITCODE -ne 0) {
            throw "flash_attention_build_commit ($head) is older than flash_attention_min_commit ($MinCommit)"
        }
    }

    Write-Host "Verified build commit $head is not earlier than flash_attention_min_commit $MinCommit"
}

Initialize-FlashAttentionRepo -Root $FlashAttentionRoot -Repo $repoUrl -Ref $buildCommit
git -C $FlashAttentionRoot submodule update --init --depth 1 csrc/composable_kernel csrc/cutlass

$BuildRoot = Join-Path $WorkspaceRoot "build"

. (Join-Path $BuildRoot "patch\patch-ck-windows.ps1") -FlashAttentionRoot $FlashAttentionRoot

Assert-BuildCommitMeetsMin -Root $FlashAttentionRoot -BuildCommit $buildCommit -MinCommit $minCommit

$resolvedCommit = (git -C $FlashAttentionRoot rev-parse HEAD).Trim()
Write-Host "Resolved flash-attention commit: $resolvedCommit"

if ($env:GITHUB_OUTPUT) {
    "fa-commit-sha=$resolvedCommit" | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8
}

. (Join-Path $BuildRoot "patch\patch-fa-inference.ps1") -FlashAttentionRoot $FlashAttentionRoot

$metaPath = Join-Path $FlashAttentionRoot ".fa-build-meta.json"
@{
    flash_attention_commit               = $resolvedCommit
    flash_attention_repo                 = $repoUrl
    flash_attention_build_commit         = $buildCommit
    flash_attention_min_commit     = $minCommit
    inference_only                       = $true
} | ConvertTo-Json | Set-Content -Path $metaPath -Encoding UTF8

# Shrink artifact upload: build only needs sources, not git metadata.
Remove-Item -Recurse -Force (Join-Path $FlashAttentionRoot ".git") -ErrorAction SilentlyContinue
Get-ChildItem -Path $FlashAttentionRoot -Recurse -Directory -Filter ".git" -ErrorAction SilentlyContinue |
    ForEach-Object { Remove-Item -Recurse -Force $_.FullName -ErrorAction SilentlyContinue }

Write-Host "Prepared flash-attention at $FlashAttentionRoot (commit=$resolvedCommit)"
