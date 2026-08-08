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

if (-not $repoUrl) {
    throw "VERSION.lock.json flash_attention_repo is missing"
}
if (-not $buildCommit) {
    throw "VERSION.lock.json flash_attention_build_commit is missing"
}
if ($buildCommit -notmatch '^[0-9a-fA-F]{40}$') {
    throw "VERSION.lock.json flash_attention_build_commit must be a 40-char git SHA"
}

Write-Host "Using flash-attention repo: $repoUrl"
Write-Host "Using flash-attention build commit: $buildCommit"

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

Initialize-FlashAttentionRepo -Root $FlashAttentionRoot -Repo $repoUrl -Ref $buildCommit
git -C $FlashAttentionRoot submodule update --init --depth 1 csrc/composable_kernel csrc/cutlass

$resolvedCommit = (git -C $FlashAttentionRoot rev-parse HEAD).Trim().ToLowerInvariant()
$expectedCommit = $buildCommit.ToLowerInvariant()
if ($resolvedCommit -ne $expectedCommit) {
    throw "Resolved flash-attention commit ($resolvedCommit) does not match flash_attention_build_commit ($expectedCommit)"
}

Write-Host "Resolved flash-attention commit: $resolvedCommit"

if ($env:GITHUB_OUTPUT) {
    "fa-commit-sha=$resolvedCommit" | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8
}

$BuildRoot = Join-Path $WorkspaceRoot "build"
. (Join-Path $BuildRoot "patch\patch-fa-inference.ps1") -FlashAttentionRoot $FlashAttentionRoot

Remove-Item -Recurse -Force (Join-Path $FlashAttentionRoot ".git") -ErrorAction SilentlyContinue
Get-ChildItem -Path $FlashAttentionRoot -Recurse -Directory -Filter ".git" -ErrorAction SilentlyContinue |
    ForEach-Object { Remove-Item -Recurse -Force $_.FullName -ErrorAction SilentlyContinue }

Write-Host "Prepared flash-attention at $FlashAttentionRoot (commit=$resolvedCommit)"
