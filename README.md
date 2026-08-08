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

## Build profile

This workflow builds an **inference-only** wheel for ComfyUI:

- CK kernels: **fwd + fwd_appendkv + fwd_splitkv** (`generate.py` skips **bwd** → no `fmha_bwd_*` backward kernels in the wheel; forward inference works; **not for** workloads that need attention gradients, e.g. diffusion training or LoRA/fine-tuning with `flash_attn` backward)
- Compile flag **`-DFLASHATTENTION_DISABLE_BACKWARD`** (enabled by `patch-fa-inference.ps1`; `setup-rocm-env.ps1` sets `FLASHATTENTION_DISABLE_BACKWARD=TRUE`) — strips backward C++ dispatch in the extension; complements the line above; **no training / backward pass**
- `OPT_DIM=32,64,128,256` (same head-dim tiers as upstream default)
- Fits GitHub hosted runner **6h** timeout; full upstream build needs ~20h+

### Ninja build scale (inference profile)

| Scope | Approx. ninja targets | Notes |
|-------|----------------------|-------|
| Full wheel (serial / link) | **~924** | 3 directions (fwd + fwd_appendkv + fwd_splitkv) × 4 head dims, no bwd |
| Single OPT_DIM shard (parallel compile) | **~230** | Shared `csrc/flash_attn_ck` + one dim's `build/fmha_*_dNN_*` kernels |

> Full upstream (with bwd) is **~1837** targets — not feasible within 6h.

## Trigger

| Workflow | Purpose | Trigger |
|----------|---------|---------|
| **Build FlashAttention CK serial (Windows gfx1201)** | Single-job build + cache resume (`serial-v2`) | **Manual only** |
| **Build FlashAttention CK parallel (Windows gfx1201)** | 4-way `OPT_DIM` compile + artifact sharding + cache resume (`parallel-d{dim}-v2`) + link | **Manual only** |

> Push to `main` does **not** auto-trigger builds.

**Manual inputs (both workflows):**

| Input | Default | Description |
|-------|---------|-------------|
| `flash_attn_ref` | `main` | branch / tag / **commit SHA** |
| `max_jobs` | `4` | ninja parallelism (use `2` if OOM) |
| `use_locked_commit` | `false` | when `true`, pin FA source to **`flash_attention_min_commit`** in `VERSION.lock.json` |

### Shared components

Both workflows share:

- `.github/actions/fa-prep-artifact` — clone + patch + upload source
- `.github/actions/fa-rocm-toolchain` — Python / MSVC / torch / rocm devel
- `.github/actions/fa-download-src` — download prep artifact
- `build/prep-flash-attention.ps1`, `build/setup-rocm-env.ps1`, `build/smoke-test-wheel.ps1`

Parallel workflow (`build-fa2-ck-gfx1201-parallel.yml`) additionally uses `build/compile-opt-dim.ps1`, `build/link_parallel_wheel.py`, `build/validate-link-staging.ps1`.

### Parallel compile vs link

| Stage | Command | Why |
|-------|---------|-----|
| **compile** (each shard) | `setup.py build_ext --inplace` | Builds one `OPT_DIM` ninja graph; uploads `.obj` artifacts |
| **link** | `bdist_wheel` (in-process + ninja patch to merge objs) | Needs full `OPT_DIM=32,64,128,256` setup graph for final link; prebuilt objs skip recompile |

Both use the same `NinjaBuildExtension`; Release layout is compatible.

## CI strategy

### Serial (`build-fa2-ck-gfx1201-serial.yml`, default)

| Job | Role | Timeout |
|-----|------|---------|
| `prep-fa-src` | clone + patch, upload source artifact | 45 min |
| `build-win-gfx1201` | toolchain, cache restore, `build-bdist-wheel.ps1` | 6 h |

- **Prep / Build split** + **actions/cache** on `build/` (key prefix `serial-v2`, `save-always: true`) for timeout resume (**Re-run all jobs**).

### Parallel (`build-fa2-ck-gfx1201-parallel.yml`, OPT_DIM ×4)

| Job | Role | Timeout |
|-----|------|---------|
| `prep-fa-src` | same prep action | 45 min |
| `compile-d32` … `compile-d256` | one `OPT_DIM` shard each, cache restore, upload `.obj` | 6 h each |
| `link-wheel` | validate staging → merge objs + link + wheel | 6 h |

Shorter wall clock (~1–2h) but more total runner minutes. Same wheel artifact as serial.

- **Link pre-check**: `validate-link-staging.ps1` ensures all four staging dirs exist, each shard has dim-specific kernel objs, no cross-shard contamination.
- **actions/cache** per shard on `build/`, key prefix `parallel-d{dim}-v2`; restore-keys match hash prefix only (no broad `-gfx1201-` fallback); timeout resume via **Re-run failed jobs**.
- **link-wheel** still requires all four compile jobs to succeed and upload obj artifacts.

> Cache keys are isolated: serial uses `serial-v2`, parallel uses `parallel-d32-v2` / `d64` / `d128` / `d256` — the two workflows do not share cache entries.

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
