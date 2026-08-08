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
        Replace = "Single"
    },
    @{
        Name    = "enable-disable-backward-flag"
        Before  = '# "-DFLASHATTENTION_DISABLE_BACKWARD",'
        After   = '"-DFLASHATTENTION_DISABLE_BACKWARD",'
        Replace = "All"
    }
)

function Test-SubstringCount {
    param(
        [string]$Haystack,
        [string]$Needle
    )
    if (-not $Needle) { return 0 }
    $count = 0
    $start = 0
    while (($idx = $Haystack.IndexOf($Needle, $start)) -ge 0) {
        $count++
        $start = $idx + $Needle.Length
    }
    return $count
}

Write-Host "Pre-check: verifying patch points in $setup"
foreach ($point in $patchPoints) {
    $beforeCount = Test-SubstringCount $content $point.Before
    $afterCount = Test-SubstringCount $content $point.After

    if ($beforeCount -lt 1) {
        if ($afterCount -ge 1) {
            throw "patch-fa-inference.ps1: pre-check failed for '$($point.Name)': already patched (after-state present, before-state missing)"
        }
        throw "patch-fa-inference.ps1: pre-check failed for '$($point.Name)': expected before-state not found in setup.py"
    }

    Write-Host "  OK $($point.Name): before-state found ($beforeCount occurrence(s))"
}

$original = $content
foreach ($point in $patchPoints) {
    if ($point.Replace -eq "All") {
        $content = $content.Replace($point.Before, $point.After)
    } else {
        if (-not $content.Contains($point.Before)) {
            throw "patch-fa-inference.ps1: apply failed for '$($point.Name)': before-state missing during replace"
        }
        $content = $content.Replace($point.Before, $point.After)
    }
}

if ($content -eq $original) {
    throw "patch-fa-inference.ps1: setup.py content unchanged after patch"
}

$utf8NoBom = New-Object System.Text.UTF8Encoding $false
[System.IO.File]::WriteAllText($setup, $content, $utf8NoBom)

Write-Host "Post-check: verifying patch results in $setup"
$verify = Get-Content $setup -Raw -Encoding UTF8

foreach ($point in $patchPoints) {
    if ((Test-SubstringCount $verify $point.Before) -gt 0) {
        throw "patch-fa-inference.ps1: post-check failed for '$($point.Name)': before-state still present"
    }
    if ((Test-SubstringCount $verify $point.After) -lt 1) {
        throw "patch-fa-inference.ps1: post-check failed for '$($point.Name)': after-state not found"
    }
    Write-Host "  OK $($point.Name): after-state confirmed"
}

if ($verify -match 'for direction in \["fwd", "fwd_appendkv", "fwd_splitkv", "bwd"\]') {
    throw "patch-fa-inference.ps1: post-check failed: generate loop still includes bwd"
}
if ($verify -notmatch 'for direction in \["fwd", "fwd_appendkv", "fwd_splitkv"\]:') {
    throw "patch-fa-inference.ps1: post-check failed: inference-only generate loop not found"
}
if ($verify -notmatch '(?m)^\s*"-DFLASHATTENTION_DISABLE_BACKWARD",') {
    throw "patch-fa-inference.ps1: post-check failed: FLASHATTENTION_DISABLE_BACKWARD not enabled"
}

Write-Host "Patched $setup for inference-only CK build (no bwd, keep fwd/appendkv/splitkv)"
