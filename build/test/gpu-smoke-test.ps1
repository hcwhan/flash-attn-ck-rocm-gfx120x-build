param(
    [string]$PythonExe = "python",

    [Parameter(Mandatory = $true)]
    [string]$WorkspaceRoot
)

$ErrorActionPreference = "Stop"

. (Join-Path (Split-Path $PSScriptRoot -Parent) "common\paths.ps1") -WorkspaceRoot $WorkspaceRoot
$BuildRoot = $script:BuildRoot
. (Join-Path $BuildRoot "config\read-version-lock.ps1") -WorkspaceRoot $WorkspaceRoot

$optDimsArg = ($OptDimList | ForEach-Object { [int]$_ }) -join ","

Write-Host "GPU smoke test on $GPU_ARCHS (requires ROCm PyTorch + GPU)"
Write-Host "OPT_DIM tiers: $($OptDimList -join ', ')"

$pyCode = @"
import sys
import torch
from flash_attn import flash_attn_func

expected_arch = sys.argv[1].strip().lower()
opt_dims = [int(x) for x in sys.argv[2].split(',') if x]

if not torch.cuda.is_available():
    raise SystemExit('ERROR: torch.cuda.is_available() is False; need ROCm GPU')

device = torch.device('cuda')
props = torch.cuda.get_device_properties(0)
arch = (getattr(props, 'gcnArchName', None) or '').lower()
print(f'GPU: {props.name} (gcnArchName={arch or "unknown"})')

if expected_arch not in arch:
    raise SystemExit(f'ERROR: expected {expected_arch!r} not found in gcnArchName {arch!r}')

batch, seqlen, nheads = 1, 64, 4
for headdim in opt_dims:
    q = torch.randn(batch, seqlen, nheads, headdim, device=device, dtype=torch.float16)
    k = torch.randn(batch, seqlen, nheads, headdim, device=device, dtype=torch.float16)
    v = torch.randn(batch, seqlen, nheads, headdim, device=device, dtype=torch.float16)
    out = flash_attn_func(q, k, v, causal=True)
    if out.shape != q.shape:
        raise SystemExit(f'ERROR: headdim={headdim} unexpected output shape {out.shape}')
    if not torch.isfinite(out).all():
        raise SystemExit(f'ERROR: headdim={headdim} output has non-finite values')
    torch.cuda.synchronize()
    print(f'GPU forward OK headdim={headdim} shape={tuple(out.shape)}')
"@

& $PythonExe -c $pyCode $GPU_ARCHS $optDimsArg
if ($LASTEXITCODE -ne 0) {
    throw "GPU smoke test failed (exit $LASTEXITCODE)"
}
