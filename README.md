# flash-attn-rocm-gfx1201-build

[中文文档](README.zh-CN.md)

GitHub Actions workflow to build **FlashAttention 2 CK backend** for **Windows / gfx1201 / PyTorch 2.12.0+rocm7.14.0**.

## Target

| Item | Value |
|------|-------|
| GPU | AMD RDNA4 (`gfx1201`, e.g. RX 9070) |
| OS | Windows |
| Python | 3.12 |
| PyTorch | `2.12.0+rocm7.14.0` |
| flash-attention | `main` (includes RDNA4 via PR [#2400](https://github.com/Dao-AILab/flash-attention/pull/2400); tag `v2.8.3.post1` lacks `gfx1201`) |
| Runner | `windows-2022` (hosted only) |

## Trigger

- Manual: Actions -> **Build FlashAttention CK (Windows gfx1201)** -> Run workflow
- Tag push: `fa-ck-v*`

> Push to `main` does **not** auto-trigger builds (avoids duplicate runs when pushing workflow fixes).

## Build profile

This workflow builds an **inference-only** wheel for ComfyUI:

- CK kernels: **fwd only** (no bwd / kv-cache variants)
- `OPT_DIM=64,128,256` (covers common diffusion head dims)
- Fits GitHub hosted runner **6h** timeout; full upstream build needs ~20h+

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
