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
$original = $content

# ComfyUI inference: skip bwd only; keep fwd_appendkv/fwd_splitkv for link symbols.
$content = $content.Replace(
    'for direction in ["fwd", "fwd_appendkv", "fwd_splitkv", "bwd"]:',
    'for direction in ["fwd", "fwd_appendkv", "fwd_splitkv"]:'
)

# Enable backward disable flag in CK cc_flag (was commented out upstream).
$content = $content.Replace(
    '# "-DFLASHATTENTION_DISABLE_BACKWARD",',
    '"-DFLASHATTENTION_DISABLE_BACKWARD",'
)

if ($content -eq $original) {
    throw "patch-fa-inference.ps1: setup.py content unchanged; upstream layout may have drifted"
}

Set-Content -Path $setup -Value $content -Encoding UTF8 -NoNewline

$verify = Get-Content $setup -Raw -Encoding UTF8
if ($verify -match 'for direction in \["fwd", "fwd_appendkv", "fwd_splitkv", "bwd"\]') {
    throw "patch-fa-inference.ps1: generate loop still includes bwd after patch"
}
if ($verify -notmatch 'for direction in \["fwd", "fwd_appendkv", "fwd_splitkv"\]:') {
    throw "patch-fa-inference.ps1: inference-only generate loop not found in setup.py"
}
if ($verify -notmatch '(?m)^\s*"-DFLASHATTENTION_DISABLE_BACKWARD",') {
    throw "patch-fa-inference.ps1: FLASHATTENTION_DISABLE_BACKWARD not enabled in setup.py"
}

Write-Host "Patched $setup for inference-only CK build (no bwd, keep fwd/appendkv/splitkv)"
