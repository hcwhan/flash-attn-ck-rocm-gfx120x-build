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
        Before  = '# "-DFLASHATTENTION_DISABLE_BACKWARD",'
        After   = '"-DFLASHATTENTION_DISABLE_BACKWARD",'
    }
)

foreach ($point in $patchPoints) {
    if (-not $content.Contains($point.Before)) {
        throw "patch-fa-inference.ps1: before-state not found for '$($point.Name)'"
    }
    Write-Host "  OK $($point.Name): before-state found"
}

foreach ($point in $patchPoints) {
    $content = $content.Replace($point.Before, $point.After)
}

$utf8NoBom = New-Object System.Text.UTF8Encoding $false
[System.IO.File]::WriteAllText($setup, $content, $utf8NoBom)

$verify = Get-Content $setup -Raw -Encoding UTF8
foreach ($point in $patchPoints) {
    if ($verify.Contains($point.Before)) {
        throw "patch-fa-inference.ps1: before-state still present for '$($point.Name)'"
    }
    if (-not $verify.Contains($point.After)) {
        throw "patch-fa-inference.ps1: after-state not found for '$($point.Name)'"
    }
    Write-Host "  OK $($point.Name): patched"
}

Write-Host "Patched $setup for inference-only CK build"
