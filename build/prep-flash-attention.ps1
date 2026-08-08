param(
    [Parameter(Mandatory = $true)]
    [string]$FlashAttentionRoot,

    [Parameter(Mandatory = $true)]
    [string]$FlashAttentionRef,

    [string]$WorkspaceRoot = "",

    [switch]$UseLockedCommit
)

$ErrorActionPreference = "Stop"

$repoUrl = "https://github.com/Dao-AILab/flash-attention.git"
$minCommit = $null

if ($WorkspaceRoot) {
    $lockPath = Join-Path $WorkspaceRoot "VERSION.lock.json"
    if (Test-Path $lockPath) {
        $lock = Get-Content $lockPath -Raw | ConvertFrom-Json
        if ($lock.flash_attention_min_commit) {
            $minCommit = [string]$lock.flash_attention_min_commit
        }
    }
}

if ($UseLockedCommit) {
    if (-not $minCommit) {
        throw "UseLockedCommit requested but VERSION.lock.json flash_attention_min_commit is missing"
    }
    $FlashAttentionRef = $minCommit
    Write-Host "Using locked flash-attention commit from VERSION.lock.json: $FlashAttentionRef"
}

function Test-IsGitCommitRef {
    param([string]$Ref)
    return $Ref -match '^[0-9a-fA-F]{7,40}$'
}

function Initialize-FlashAttentionRepo {
    param(
        [string]$Root,
        [string]$Ref
    )

    $parent = Split-Path -Parent $Root
    if (-not (Test-Path $parent)) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }
    if (Test-Path $Root) {
        Remove-Item -Recurse -Force $Root
    }

    if (Test-IsGitCommitRef $Ref) {
        Write-Host "Cloning flash-attention at commit $Ref"
        git -c core.longpaths=true clone --filter=blob:none --no-checkout $repoUrl $Root
        git -c core.longpaths=true -C $Root fetch --depth 1 origin $Ref
        git -C $Root checkout FETCH_HEAD
        return
    }

    Write-Host "Cloning flash-attention branch/tag $Ref"
    git -c core.longpaths=true clone --depth 1 --branch $Ref $repoUrl $Root
}

function Assert-MinFlashAttentionCommit {
    param(
        [string]$Root,
        [string]$RequiredCommit
    )

    if (-not $RequiredCommit) {
        return
    }

    $head = (git -C $Root rev-parse HEAD).Trim()
    if ($head.StartsWith($RequiredCommit) -or $RequiredCommit.StartsWith($head)) {
        Write-Host "Verified flash-attention HEAD $head matches locked commit $RequiredCommit"
        return
    }

    git -c core.longpaths=true -C $Root fetch --depth 1 origin $RequiredCommit
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to fetch minimum flash-attention commit $RequiredCommit"
    }

    git -C $Root merge-base --is-ancestor $RequiredCommit HEAD
    if ($LASTEXITCODE -ne 0) {
        throw "flash-attention HEAD ($head) is older than required minimum $RequiredCommit from VERSION.lock.json"
    }

    Write-Host "Verified flash-attention HEAD $head includes minimum commit $RequiredCommit"
}

Initialize-FlashAttentionRepo -Root $FlashAttentionRoot -Ref $FlashAttentionRef
git -C $FlashAttentionRoot submodule update --init --depth 1 csrc/composable_kernel csrc/cutlass

if ($minCommit) {
    Assert-MinFlashAttentionCommit -Root $FlashAttentionRoot -RequiredCommit $minCommit
}

$resolvedCommit = (git -C $FlashAttentionRoot rev-parse HEAD).Trim()
Write-Host "Resolved flash-attention commit: $resolvedCommit"

if ($env:GITHUB_OUTPUT) {
    "fa-commit-sha=$resolvedCommit" | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8
}

. (Join-Path $PSScriptRoot "patch-fa-inference.ps1") -FlashAttentionRoot $FlashAttentionRoot

$metaPath = Join-Path $FlashAttentionRoot ".fa-build-meta.json"
@{
    flash_attention_commit = $resolvedCommit
    flash_attention_ref    = $FlashAttentionRef
    inference_only         = $true
} | ConvertTo-Json | Set-Content -Path $metaPath -Encoding UTF8

# Shrink artifact upload: build only needs sources, not git metadata.
Remove-Item -Recurse -Force (Join-Path $FlashAttentionRoot ".git") -ErrorAction SilentlyContinue
Get-ChildItem -Path $FlashAttentionRoot -Recurse -Directory -Filter ".git" -ErrorAction SilentlyContinue |
    ForEach-Object { Remove-Item -Recurse -Force $_.FullName -ErrorAction SilentlyContinue }

Write-Host "Prepared flash-attention at $FlashAttentionRoot (ref=$FlashAttentionRef, commit=$resolvedCommit)"
