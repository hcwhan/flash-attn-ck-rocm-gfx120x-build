# flash-attn-rocm-gfx1201-build

[中文文档](README.zh-CN.md)

GitHub Actions workflow to build **FlashAttention 2 CK backend** for **Windows / gfx1201 / PyTorch 2.12.0+rocm7.14.0**.

## Target

| Item | Value |
|------|-------|
| GPU arch | `gfx1201` (RDNA4, Navi 48) |
| Supported GPUs | See table below |
| OS | Windows |
| Python | 3.12 |
| PyTorch | `2.12.0+rocm7.14.0` |
| flash-attention | `main` (includes RDNA4 via PR [#2400](https://github.com/Dao-AILab/flash-attention/pull/2400); tag `v2.8.3.post1` lacks `gfx1201`) |
| Runner | `windows-2022` (hosted only) |

### Supported GPUs (`gfx1201`)

Per [AMD ROCm GPU specifications](https://rocm.docs.amd.com/en/latest/reference/gpu-arch-specs.html):

| Category | Model |
|----------|-------|
| Consumer | Radeon RX 9070 XT |
| Consumer | Radeon RX 9070 |
| Consumer | Radeon RX 9070 GRE |
| Workstation | Radeon AI PRO R9700 |
| Workstation | Radeon AI PRO R9700S |
| Workstation | Radeon AI PRO R9600D |

> RDNA4 **`gfx1200`** models (e.g. RX 9060 / RX 9060 XT) use a different LLVM target and are **not** included in this wheel.

## Trigger

- Manual: Actions -> **Build FlashAttention CK (Windows gfx1201)** -> Run workflow
- Tag push: `fa-ck-v*`

> Push to `main` does **not** auto-trigger builds (avoids duplicate runs when pushing workflow fixes).

## Build profile

This workflow builds an **inference-only** wheel for ComfyUI:

- CK kernels: **fwd only** (no bwd / kv-cache variants)
- `OPT_DIM=32,64,128,256` (same head-dim tiers as upstream default)
- Fits GitHub hosted runner **6h** timeout; full upstream build needs ~20h+

## CI strategy (two jobs + resume cache)

| Job | Role | Timeout |
|-----|------|---------|
| `prep-fa-src` | clone + patch flash-attention, upload source artifact | 45 min |
| `build-win-gfx1201` | install torch/rocm, restore cache, compile wheel | 6 h |

- **Prep / Build split**: the compile job keeps its full 6h budget for ninja (saves ~20–40 min vs a single job).
- **actions/cache**: caches `C:\fa\flash-attention\build` (ninja `.obj` + generated kernels); `save-always: true`.
- **Resume after timeout**: re-run the workflow with the same `flash_attn_ref` and unchanged patch scripts. Cache keys include PyTorch version, `GPU_ARCHS`, `OPT_DIM`, patch script hashes, and `flash_attn_ref`; changing ref or patches starts a cold build.

> Actions → timed-out or failed run → **Re-run all jobs** (not “Re-run failed jobs” only, or the prep artifact may be missing).

## Output

Artifact: `flash-attn-ck-gfx1201-cp312-rocm714`

Expected wheel name pattern:

```text
flash_attn-*+rocm714torch212cxx11abiTRUE-cp312-cp312-win_amd64.whl
```

## Install on ComfyUI portable Python

Replace `<ComfyUI>` with your ComfyUI root directory:

```powershell
$PY = "<ComfyUI>\python_embeded\python.exe"
& $PY -m pip install .\downloaded.whl
```

Then switch ComfyUI launch arg from `--use-pytorch-cross-attention` to `--use-flash-attention`.

## Repository

https://github.com/hcwhan/flash-attn-rocm-gfx1201-build
