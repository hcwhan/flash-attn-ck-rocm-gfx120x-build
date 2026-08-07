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

# ComfyUI inference: fwd only, no bwd / kv-cache variants (cuts ~75% compile objects).
$content = $content.Replace(
    'for direction in ["fwd", "fwd_appendkv", "fwd_splitkv", "bwd"]:',
    'for direction in ["fwd"]:'
)

# Enable backward disable flag in CK cc_flag (was commented out upstream).
$content = $content.Replace(
    '# "-DFLASHATTENTION_DISABLE_BACKWARD",',
    '"-DFLASHATTENTION_DISABLE_BACKWARD",'
)

Set-Content -Path $setup -Value $content -Encoding UTF8 -NoNewline
Write-Host "Patched $setup for inference-only CK build (fwd only, DISABLE_BACKWARD)"
