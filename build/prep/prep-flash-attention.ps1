param(
    [Parameter(Mandatory = $true)]
    [string]$FlashAttentionRoot,

    [Parameter(Mandatory = $true)]
    [string]$WorkspaceRoot
)

$ErrorActionPreference = "Stop"

$BuildRoot = Join-Path $WorkspaceRoot "build"
. (Join-Path $BuildRoot "config\read-version-lock.ps1") -WorkspaceRoot $WorkspaceRoot

Write-Host "Using flash-attention repo: $FLASH_ATTENTION_REPO"
Write-Host "Using flash-attention build commit: $FLASH_ATTENTION_BUILD_COMMIT"

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

Initialize-FlashAttentionRepo -Root $FlashAttentionRoot -Repo $FLASH_ATTENTION_REPO -Ref $FLASH_ATTENTION_BUILD_COMMIT
git -C $FlashAttentionRoot submodule update --init --depth 1 csrc/composable_kernel csrc/cutlass

. (Join-Path $BuildRoot "patch\patch-fa-inference.ps1") -FlashAttentionRoot $FlashAttentionRoot

Remove-Item -Recurse -Force (Join-Path $FlashAttentionRoot ".git")

Write-Host "Prepared flash-attention at $FlashAttentionRoot (commit=$FLASH_ATTENTION_BUILD_COMMIT)"
