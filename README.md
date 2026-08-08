# flash-attn-rocm-gfx1201-build

[中文文档](README.zh-CN.md)

GitHub Actions workflow to build **FlashAttention 2 CK backend** for **Windows / gfx1201 / PyTorch 2.12.0+rocm7.14.0**.

Toolchain versions are pinned in **`VERSION.lock.json`** and loaded via `.github/actions/fa-read-version-lock`.

## Target

| Item | Value |
|------|-------|
| GPU arch | `gfx1201` (RDNA4) |
| OS | Windows |
| Python | 3.12 |
| PyTorch | `2.12.0+rocm7.14.0` |
| flash-attention | `VERSION.lock.json` **`flash_attention_build_commit`** |
| Runner | `windows-2022` (hosted) |

### Source pins (`VERSION.lock.json`)

| Field | Role |
|-------|------|
| `flash_attention_repo` | Upstream git URL |
| `flash_attention_build_commit` | Exact commit cloned each build; **bump to upgrade FA** |
| `flash_attention_min_commit` | Minimum gfx1201 commit ([PR #2400](https://github.com/Dao-AILab/flash-attention/pull/2400)); **human-readable lock marker** |
| `flash_attention_build_commit_date` | UTC date for that commit; **human-readable only**, not used by scripts/CI |
| `expected_wheel_pattern` | Glob for smoke-test wheel name |
| `wheel_local_version` | `+local` tag appended to the wheel version (fed to `FLASH_ATTN_LOCAL_VERSION`) |
| `wheel_artifact_name` | GitHub Actions artifact name |

Prep clones **`flash_attention_build_commit`** (`fetch` + `checkout FETCH_HEAD`).

## Build profile

**Inference-only** wheel for ComfyUI: fwd + fwd_appendkv + fwd_splitkv (no bwd), `-DFLASHATTENTION_DISABLE_BACKWARD`, `cxx11abiTRUE`, `OPT_DIM=32,64,128,256`.

| Scope | Approx. ninja targets |
|-------|----------------------|
| Full link wheel | **~924** |
| Single OPT_DIM shard | **~230** |

## Trigger

| Workflow | Purpose | Trigger |
|----------|---------|---------|
| **Build FlashAttention CK serial (Windows gfx1201)** | Single-job full build + cache (`serial-v4`) | **Manual only** |
| **Build FlashAttention CK parallel (Windows gfx1201)** | OPT_DIM shard compile + link (`parallel-v4-d{dim}`) | **Manual only** |

Push to `main` does **not** auto-trigger builds.

**Manual inputs (both workflows):**

| Input | Default | Description |
|-------|---------|-------------|
| `ninja_workers` | `4` | Ninja parallel workers (use `2` if OOM) |
| `skip_cache_restore` | `true` | Skip cache restore during testing; set `false` when stable |

### Serial (`build-fa2-ck-gfx1201-serial.yml`)

| Job | Role | Timeout |
|-----|------|---------|
| `prep-fa-src` | clone + patch, upload source | 45 min |
| `build-win-gfx1201` | toolchain, cache, full `build-bdist-wheel.ps1` | 6 h |

### Parallel (`build-fa2-ck-gfx1201-parallel.yml`)

| Job | Role | Timeout |
|-----|------|---------|
| `prep-fa-src` | same prep | 45 min |
| `compile-d32` … `d256` | one OPT_DIM shard each, upload `.obj` | 6 h each |
| `link-wheel` | merge objs + link + wheel + CPU smoke test | 6 h |

Cache keys include the repository commit SHA and a toolchain fingerprint (MSVC toolset + ROCm clang + pip toolchain versions); **exact match only** (no `restore-keys`). Serial uses `serial-v4`, parallel uses `parallel-v4-d{dim}` — isolated from each other. Link uses **first lock `opt_dim` tier** (`32`) for shared objs only.

### Build stages

Single entry point for compile and wheel packaging: `build-fa-steps.py` (in-process `exec_module(setup.py)`), one of three `--step` modes:

| step | Role |
|------|------|
| `compile` | `build_ext` compile; stamps existing objects so the ninja cache pays off |
| `wheel` | stamp + `bdist_wheel` (objects from the in-place compile) |
| `merge-and-wheel` | staging validation + FORCE_BUILD check + merge objects + stamp + `bdist_wheel` |

Serial and parallel compose the same entry; both produce identical wheels:

| Mode | Invocation sequence | OPT_DIM |
|------|---------------------|---------|
| Serial build | `--step compile` → `--step wheel` (no staging) | full |
| Parallel compile | `--step compile` (once per shard) | single shard |
| Parallel link | `--step merge-and-wheel` + staging | full (env) |

Env is set uniformly via `base/init-fa-build-env.ps1`.

## Output

Artifact: **`wheel_artifact_name`** — `.whl`, `.sha256`, `wheel.manifest.json`.

Expected pattern: `flash_attn-*+rocm714torch212cxx11abiTRUE-cp312-cp312-win_amd64.whl`

## Verification

| Check | Script |
|-------|--------|
| CI CPU smoke test | `build/8.verify - wheel-smoke-test.ps1` |
| Pre-deploy GPU smoke test (gfx1201 hardware) | `build/9.test - gpu-smoke-test.ps1` |

Run `gpu-smoke-test.ps1` on gfx1201 before deploy.

## ComfyUI install

```powershell
& "<ComfyUI>\python_embeded\python.exe" -m pip install .\downloaded.whl
```

Use launch arg `--use-flash-attention`.

See [AGENTS.md](AGENTS.md) for maintainer conventions.
