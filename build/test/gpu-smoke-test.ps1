param(
    [string]$PythonExe = "python",

    [string]$WorkspaceRoot = "",

    [string]$ExpectedGpuArch = ""
)

$ErrorActionPreference = "Stop"

. (Join-Path (Split-Path $PSScriptRoot -Parent) "common\paths.ps1") -WorkspaceRoot $WorkspaceRoot
$WorkspaceRoot = $script:WorkspaceRoot
$BuildRoot = $script:BuildRoot

. (Join-Path $BuildRoot "config\read-version-lock.ps1") -WorkspaceRoot $WorkspaceRoot

if (-not $ExpectedGpuArch) {
    $ExpectedGpuArch = $GPU_ARCHS
}
if (-not $ExpectedGpuArch) {
    throw "Expected GPU arch is missing (pass -ExpectedGpuArch or set VERSION.lock.json gpu_archs)"
}

$optDimsArg = ($OptDimList | ForEach-Object { [int]$_ }) -join ","

Write-Host "GPU smoke test: requires $ExpectedGpuArch + ROCm PyTorch (not runnable on GitHub hosted runners)"
Write-Host "OPT_DIM tiers from lock: $($OptDimList -join ', ')"

$pyCode = @"
import re
import sys
import torch
from flash_attn import flash_attn_func

def parse_expected_archs(raw: str) -> list[str]:
    parts = [p.strip().lower() for p in re.split(r'[,;\\s]+', raw) if p.strip()]
    for arch in parts:
        if not re.fullmatch(r'gfx\\d+', arch):
            raise SystemExit(
                f'ERROR: invalid GPU arch token {arch!r}; expected full LLVM target like gfx1201'
            )
    if not parts:
        raise SystemExit('ERROR: expected GPU arch list is empty')
    return parts

def extract_gcn_arch_tokens(gcn_arch_name: str) -> set[str]:
    return set(re.findall(r'gfx\\d+', gcn_arch_name.lower()))

expected_archs = parse_expected_archs(sys.argv[1])
opt_dims = [int(x) for x in sys.argv[2].split(',') if x]

if not torch.cuda.is_available():
    raise SystemExit('ERROR: torch.cuda.is_available() is False; need ROCm GPU')

device = torch.device('cuda')
props = torch.cuda.get_device_properties(0)
arch = (getattr(props, 'gcnArchName', None) or '').lower()
print(f'GPU: {props.name} (capability {props.major}.{props.minor}, gcnArchName={arch or "unknown"})')

device_archs = extract_gcn_arch_tokens(arch)
if not any(exp in device_archs for exp in expected_archs):
    raise SystemExit(
        f'ERROR: expected GPU arch(s) {expected_archs!r} not found in gcnArchName tokens {sorted(device_archs)!r}'
    )

batch, seqlen, nheads = 1, 64, 4
for headdim in opt_dims:
    q = torch.randn(batch, seqlen, nheads, headdim, device=device, dtype=torch.float16)
    k = torch.randn(batch, seqlen, nheads, headdim, device=device, dtype=torch.float16)
    v = torch.randn(batch, seqlen, nheads, headdim, device=device, dtype=torch.float16)

    out = flash_attn_func(q, k, v, causal=True)
    if out.shape != q.shape:
        raise SystemExit(f'ERROR: headdim={headdim} unexpected output shape {out.shape}, expected {q.shape}')
    if not torch.isfinite(out).all():
        bad = (~torch.isfinite(out)).sum().item()
        raise SystemExit(f'ERROR: headdim={headdim} output has {bad} non-finite value(s)')

    torch.cuda.synchronize()
    print(f'GPU forward OK headdim={headdim} shape={tuple(out.shape)} dtype={out.dtype}')
"@

& $PythonExe -c $pyCode $ExpectedGpuArch $optDimsArg
if ($LASTEXITCODE -ne 0) {
    throw "GPU smoke test failed (exit $LASTEXITCODE)"
}
