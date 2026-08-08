param(
    [Parameter(Mandatory = $true)]
    [string]$FlashAttentionRoot
)

$ErrorActionPreference = "Stop"

$setup = Join-Path $FlashAttentionRoot "setup.py"
if (-not (Test-Path $setup)) {
    throw "setup.py not found: $setup"
}

$content = Get-Content $setup -Raw -Encoding UTF8

$patchPoints = @(
    @{
        Name    = "generate-loop-skip-bwd"
        Before  = 'for direction in ["fwd", "fwd_appendkv", "fwd_splitkv", "bwd"]:'
        After   = 'for direction in ["fwd", "fwd_appendkv", "fwd_splitkv"]:'
    },
    @{
        Name    = "enable-disable-backward-flag"
        # Regex (with before-state check): uncomment ONLY the CK extension flags
        # occurrence. setup.py has a second commented occurrence in the CUDA
        # nvcc flags list; a plain Replace would uncomment both. The pattern is
        # CRLF/LF agnostic for Windows checkout line endings.
        Regex   = $true
        Before  = '(?m)(-DUSE_PROF_API=1",\r?\n\s*)# "-DFLASHATTENTION_DISABLE_BACKWARD",'
        After   = '${1}"-DFLASHATTENTION_DISABLE_BACKWARD",'
    }
)

foreach ($point in $patchPoints) {
    $pattern = if ($point.Regex) { $point.Before } else { [regex]::Escape($point.Before) }
    if (-not [regex]::IsMatch($content, $pattern)) {
        throw "patch-fa-inference.ps1: before-state not found for '$($point.Name)'"
    }
    Write-Host "  OK $($point.Name): before-state found"
}

foreach ($point in $patchPoints) {
    $pattern = if ($point.Regex) { $point.Before } else { [regex]::Escape($point.Before) }
    $content = [regex]::Replace($content, $pattern, $point.After)
    Write-Host "  OK $($point.Name): patched"
}

$utf8NoBom = New-Object System.Text.UTF8Encoding $false
[System.IO.File]::WriteAllText($setup, $content, $utf8NoBom)

Write-Host "Patched $setup for inference-only CK build"

# The bwd-free link depends on mha_bwd.cpp / mha_varlen_bwd.cpp stubbing out the
# fmha_bwd_launcher via TORCH_CHECK(false) BEFORE constructing it: the launcher
# constructor exists only in the bwd-generated fmha_bwd_api.cpp, which this patch
# prevents from being generated. Validate that guard placement so an upstream
# refactor fails fast here instead of at wheel link (LNK2019).
$ckSrcDir = Join-Path $FlashAttentionRoot "csrc\flash_attn_ck"
foreach ($bwdFile in @('mha_bwd.cpp', 'mha_varlen_bwd.cpp')) {
    $bwdPath = Join-Path $ckSrcDir $bwdFile
    if (-not (Test-Path $bwdPath)) {
        throw "patch-fa-inference.ps1: before-state not found: $bwdFile missing at $bwdPath"
    }
    $bwdContent = Get-Content $bwdPath -Raw -Encoding UTF8
    $guardIdx = $bwdContent.IndexOf('TORCH_CHECK(false')
    $launcherIdx = $bwdContent.IndexOf('fmha_bwd_launcher launcher(')
    if ($guardIdx -lt 0 -or $launcherIdx -lt 0 -or $guardIdx -gt $launcherIdx) {
        throw "patch-fa-inference.ps1: before-state not found for '$bwdFile' (TORCH_CHECK(false) guard must precede fmha_bwd_launcher construction)"
    }
    Write-Host "  OK $bwdFile: backward guard precedes launcher"
}
