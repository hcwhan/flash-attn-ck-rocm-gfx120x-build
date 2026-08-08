param(
    [Parameter(Mandatory = $true)]
    [string]$FlashAttentionRoot,

    [Parameter(Mandatory = $true)]
    [string]$FlashAttentionRef
)

$ErrorActionPreference = "Stop"

$parent = Split-Path -Parent $FlashAttentionRoot
if (-not (Test-Path $parent)) {
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
}
if (Test-Path $FlashAttentionRoot) {
    Remove-Item -Recurse -Force $FlashAttentionRoot
}

git config --global core.longpaths true
git clone --depth 1 --branch $FlashAttentionRef `
    https://github.com/Dao-AILab/flash-attention.git `
    $FlashAttentionRoot
git -C $FlashAttentionRoot submodule update --init --depth 1 csrc/composable_kernel csrc/cutlass

. (Join-Path $PSScriptRoot "patch-fa-inference.ps1") -FlashAttentionRoot $FlashAttentionRoot

# Shrink artifact upload: build only needs sources, not git metadata.
Remove-Item -Recurse -Force (Join-Path $FlashAttentionRoot ".git") -ErrorAction SilentlyContinue
Get-ChildItem -Path $FlashAttentionRoot -Recurse -Directory -Filter ".git" -ErrorAction SilentlyContinue |
    ForEach-Object { Remove-Item -Recurse -Force $_.FullName -ErrorAction SilentlyContinue }

Write-Host "Prepared flash-attention at $FlashAttentionRoot (ref=$FlashAttentionRef)"
