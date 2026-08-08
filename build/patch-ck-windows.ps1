param(
    [Parameter(Mandatory = $true)]
    [string]$FlashAttentionRoot
)

$ErrorActionPreference = "Stop"

$header = Join-Path $FlashAttentionRoot "csrc\composable_kernel\example\ck_tile\01_fmha\fmha_fwd_head_grouping.hpp"
if (-not (Test-Path $header)) {
    Write-Host "Skip CK Windows patch: head grouping header not found ($header)"
    return
}

$content = Get-Content $header -Raw -Encoding UTF8
$before = @'
#ifndef CK_TILE_FMHA_ENABLE_HEAD_GROUPING
#define CK_TILE_FMHA_ENABLE_HEAD_GROUPING 1
#endif
'@
$after = @'
#ifndef CK_TILE_FMHA_ENABLE_HEAD_GROUPING
#if defined(_WIN32)
#define CK_TILE_FMHA_ENABLE_HEAD_GROUPING 0
#else
#define CK_TILE_FMHA_ENABLE_HEAD_GROUPING 1
#endif
#endif
'@

if ($content.Contains($after)) {
    Write-Host "CK Windows patch already applied: $header"
    return
}

if (-not $content.Contains($before)) {
    throw "patch-ck-windows.ps1: expected head-grouping default block not found in $header"
}

$content = $content.Replace($before, $after)
$utf8NoBom = New-Object System.Text.UTF8Encoding $false
[System.IO.File]::WriteAllText($header, $content, $utf8NoBom)
Write-Host "Patched CK head grouping for Windows (disabled Linux sysfs/dirent path): $header"
