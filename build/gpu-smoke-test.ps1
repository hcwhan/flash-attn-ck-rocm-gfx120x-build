param(
    [string]$PythonExe = "python"
)

$ErrorActionPreference = "Stop"

Write-Host "GPU smoke test: requires gfx1201 + ROCm PyTorch (not runnable on GitHub hosted runners)"

$pyCode = @"
import torch
from flash_attn import flash_attn_func

if not torch.cuda.is_available():
    raise SystemExit("ERROR: torch.cuda.is_available() is False; need ROCm GPU")

device = torch.device("cuda")
props = torch.cuda.get_device_properties(0)
print(f"GPU: {props.name} (capability {props.major}.{props.minor})")

batch, seqlen, nheads, headdim = 1, 64, 4, 64
q = torch.randn(batch, seqlen, nheads, headdim, device=device, dtype=torch.float16)
k = torch.randn(batch, seqlen, nheads, headdim, device=device, dtype=torch.float16)
v = torch.randn(batch, seqlen, nheads, headdim, device=device, dtype=torch.float16)

out = flash_attn_func(q, k, v, causal=True)
if out.shape != q.shape:
    raise SystemExit(f"ERROR: unexpected output shape {out.shape}, expected {q.shape}")

torch.cuda.synchronize()
print("GPU forward OK", tuple(out.shape), "dtype=", out.dtype)
"@

& $PythonExe -c $pyCode
if ($LASTEXITCODE -ne 0) {
    throw "GPU smoke test failed (exit $LASTEXITCODE)"
}
