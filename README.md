# flash-attn-rocm-gfx1201-build

[中文文档](README.zh-CN.md)

GitHub Actions workflow to build **FlashAttention 2 CK backend** for **Windows / gfx1201 / PyTorch 2.12.0+rocm7.14.0**.

Toolchain versions are pinned in **`VERSION.lock.json`** and loaded into CI via `.github/actions/fa-read-version-lock`.

## Target

| Item | Value |
|------|-------|
| GPU arch | `gfx1201` (RDNA4, Navi 48) |
| Supported GPUs | See table below |
| OS | Windows |
| Python | 3.12 |
| PyTorch | `2.12.0+rocm7.14.0` |
| flash-attention | `VERSION.lock.json` **`flash_attention_build_commit`** |
| Runner | `windows-2022` (hosted only) |

### FlashAttention source pins (`VERSION.lock.json`)

| Field | Role |
|-------|------|
| `flash_attention_repo` | Upstream git URL |
| `flash_attention_min_commit` | Minimum commit with gfx1201 support ([PR #2400](https://github.com/Dao-AILab/flash-attention/pull/2400)); rarely changed |
| `flash_attention_build_commit` | Exact commit cloned for each build; **bump this to upgrade FA** |
| `flash_attention_build_commit_date` | UTC committer date for that commit (ISO 8601); **human-readable lock marker only**, not used by prep/CI |
| `expected_wheel_pattern` | Glob for the built `.whl` filename (smoke test) |
| `wheel_artifact_name` | GitHub Actions artifact name for the published wheel bundle |

Rules:

- CI/local always clone **`flash_attention_build_commit`** (no workflow ref input).
- Prep verifies **`flash_attention_build_commit`** is **not earlier than** **`flash_attention_min_commit`** (`git merge-base --is-ancestor`).
- Tag `v2.8.3.post1` lacks `gfx1201` in `allowed_archs` — do not set `flash_attention_build_commit` before the minimum.

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
- Compile flag **`-DFLASHATTENTION_DISABLE_BACKWARD`** — strips backward C++ dispatch in the extension; complements the line above; **no training / backward pass**
- **C++11 ABI (`cxx11abiTRUE`)**: the extension must match the pinned PyTorch build using `_GLIBCXX_USE_CXX11_ABI=1` (official ROCm 2.12 wheels). ABI mismatch typically breaks `import flash_attn_2_cuda`. Smoke test checks `expected_wheel_pattern` in `VERSION.lock.json`, which includes the `cxx11abiTRUE` tag
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
| **Build FlashAttention CK parallel (Windows gfx1201)** | `OPT_DIM` shards from lock (compile + artifact sharding + cache resume `parallel-v2-d{dim}`) + link | **Manual only** |

> Push to `main` does **not** auto-trigger builds.

**Manual inputs (both workflows):**

| Input | Default | Description |
|-------|---------|-------------|
| `ninja_workers` | `4` | Ninja parallel compile workers per build job (not CI job count; use `2` if OOM) |

### Shared components

Both workflows share:

- `.github/actions/fa-read-version-lock` — load `VERSION.lock.json` into `GITHUB_ENV`
- `.github/actions/fa-prep-artifact` — clone + patch + upload source (outputs resolved **FA commit SHA**)
- `.github/actions/fa-rocm-toolchain` — Python / MSVC / torch / rocm devel
- `.github/actions/fa-download-src` — download prep artifact
- `build/patch-fa-inference.ps1` — direct `setup.py` edits with pre/post verification
- `build/prep-flash-attention.ps1`, `build/init-fa-build-env.ps1`, `build/setup-rocm-env.ps1`, `build/build-bdist-wheel.ps1`, `build/smoke-test-wheel.ps1`

Serial / parallel link / parallel compile share `init-fa-build-env.ps1` + in-process `link_parallel_wheel.py`; parallel compile additionally uses `build/compile-opt-dim.ps1`. `build/validate-link-staging.ps1` is a manual CLI wrapper only (CI validates inside `link_parallel_wheel.py` during link).

### Aligned build paths

| Stage | Env init | setuptools entry | OPT_DIM |
|-------|----------|------------------|---------|
| Serial build | `init-fa-build-env.ps1` | `link_parallel_wheel.py --serial` → `bdist_wheel -v` | full |
| Parallel compile | `init-fa-build-env.ps1` | `link_parallel_wheel.py --compile-only` → `build_ext -v` | single shard |
| Parallel link | `init-fa-build-env.ps1` | `link_parallel_wheel.py` + staging → `bdist_wheel -v` | full |

All three use **in-process `exec_module(setup.py)`** and the same `NinjaBuildExtension`. Parallel compile no longer uses a subprocess or `--inplace`. The only material differences vs serial/link are **OPT_DIM scope** and **build_ext vs bdist_wheel** (compile emits objs only).

## CI strategy

### Serial (`build-fa2-ck-gfx1201-serial.yml`, default)

| Job | Role | Timeout |
|-----|------|---------|
| `prep-fa-src` | clone + patch, upload source artifact | 45 min |
| `build-win-gfx1201` | toolchain, cache restore, `build-bdist-wheel.ps1` | 6 h |

- **Prep / Build split** + **`actions/cache/restore` + `actions/cache/save`** on `build/` (key prefix `serial-v2`, save step runs with `if: always()`) for timeout resume (**Re-run all jobs**).
- **Cache key** includes the **resolved flash-attention commit SHA** from prep (`VERSION.lock.json` pin), so lock bumps do not reuse stale `.obj` files. **Exact key match only** — no `restore-keys` fallback across commits.

### Parallel (`build-fa2-ck-gfx1201-parallel.yml`, OPT_DIM ×4)

| Job | Role | Timeout |
|-----|------|---------|
| `prep-fa-src` | same prep action | 45 min |
| `compile-d*` … | one `OPT_DIM` shard each (from lock), cache restore, upload `.obj` | 6 h each |
| `link-wheel` | validate staging → merge objs + link + wheel | 6 h |

Shorter wall clock (~1–2h) but more total runner minutes. Same wheel artifact as serial.

- **Link pre-check**: `link_parallel_wheel.py` validates staging (four dirs, dim-specific kernel objs, no cross-shard contamination) before merge/link.
- **actions/cache** per shard on `build/`, key prefix `parallel-v2-d{dim}` (includes resolved FA commit SHA); **exact key match only** (no cross-commit `restore-keys`); timeout resume via **Re-run failed jobs** (obj/source artifacts retained **7 days**).
- **link-wheel** still requires all four compile jobs to succeed and upload obj artifacts.
- Each compile shard also builds shared `csrc/flash_attn_ck` objects; link uses the **first lock `opt_dim` tier** for shared objects only (duplicate compile is intentional).

> Cache keys are isolated: serial uses `serial-v2`, parallel uses `parallel-v2-` (`d32` / `d64` / `d128` / `d256`) — the two workflows do not share cache entries.

## Output

Artifact: **`wheel_artifact_name`** in `VERSION.lock.json`

Includes:

- `flash_attn-*.whl`
- `flash_attn-*.whl.sha256` (GNU `sha256sum` format)
- `wheel.manifest.json` (sha256, size, toolchain pins, FA commit)

Expected wheel name pattern (`expected_wheel_pattern` in lock):

```text
flash_attn-*+rocm714torch212cxx11abiTRUE-cp312-cp312-win_amd64.whl
```

## Verification

| Check | Where | What it proves |
|-------|-------|----------------|
| CI CPU smoke test | `build/smoke-test-wheel.ps1` | Layered checks (see table below) |
| Local GPU smoke test | `build/gpu-smoke-test.ps1` | actual `flash_attn_func` forward on gfx1201 (requires ROCm PyTorch + GPU) |

### CI CPU smoke test layers

| Layer | Check | Failure meaning |
|-------|-------|-----------------|
| L1 | Wheel name / `VERSION.lock.json` pattern | Wrong packaging or ABI tags |
| L1 | `flash_attn_2_cuda*.pyd` inside wheel archive (>1KB) | Extension not packaged |
| L2 | `pip install --force-reinstall --no-deps` | Wheel not installable |
| L3 | `find_spec` → `import flash_attn_2_cuda` → public symbol count ≥1 | Extension DLL / HIP load failed |
| L3 | Record `torch.cuda.is_available()` (usually `False` on hosted) | Diagnostic only, not a fail condition |
| L3 | `dumpbin /DEPENDENTS` when MSVC tools are available | HIP/torch DLL dependency chain |
| — | `wheel.manifest.json` `smoke_test` block + GitHub Step Summary | Audit trail |

> **L3 pass** = extension **load** confirmed on GitHub hosted runners (first green CI run proves this assumption). Does **not** prove gfx1201 kernel correctness — run `gpu-smoke-test.ps1` on GPU before deploy.

Skip L3 (wheel structure + pip only): set `FA_SKIP_EXTENSION_IMPORT=1`.

## Local build (outside CI)

On a Windows machine with MSVC, Python 3.12, and PyTorch ROCm already installed:

```powershell
cd flash-attn-rocm-gfx1201-build
. .\build\build-local.ps1 -GpuSmokeTest
```

Options: `-SkipPrep` (reuse existing `$FaSrc`), `-NinjaWorkers 2` (if OOM).

## Install on ComfyUI portable Python

Replace `<ComfyUI>` with your ComfyUI root directory:

```powershell
$PY = "<ComfyUI>\python_embeded\python.exe"
& $PY -m pip install .\downloaded.whl
```

Then switch ComfyUI launch arg from `--use-pytorch-cross-attention` to `--use-flash-attention`.
