# flash-attn-ck-rocm-gfx120x-build

[中文](README.md)

GitHub Actions workflow to build **FlashAttention 2 CK backend** for **Windows / gfx120x (RDNA4) / PyTorch 2.12.0+rocm7.14.0**.

Toolchain versions are pinned in **`VERSION.lock.json`** and loaded via `npx tsx scripts/cli.ts 01.config -w $env:GITHUB_WORKSPACE --export-github-env` in each workflow job.

## Target

| Item | Value |
|------|-------|
| GPU arch | lock **`compile.gpu_archs`** (currently `gfx1200;gfx1201`) |
| OS | Windows |
| Python | 3.12 |
| PyTorch | `2.12.0+rocm7.14.0` |
| flash-attention | `VERSION.lock.json` **`flash_attention.build_commit`** |
| Runner | `windows-2022` (hosted) |

### `VERSION.lock.json` sections

| Section | Field | Role |
|---------|-------|------|
| `toolchain` | `python`, `pytorch`, `torch_device_extra`, `rocm_index`, `rocm` | pip toolchain pins |
| `flash_attention` | `repo`, `build_commit`, `build_commit_date` | Exact FA source cloned each build; **bump `build_commit` and `build_commit_date` when upgrading FA** |
| `flash_attention` | `min_commit` | Minimum RDNA4 gfx12x commit ([PR #2400](https://github.com/Dao-AILab/flash-attention/pull/2400)); **human-readable reference only** |
| `compile` | `gpu_archs`, `ck_opt_dim`, `ck_disable_bwd` | HIP compile targets (**sole arch source**), CK FMHA `opt_dim` tiers, and whether bwd is omitted (`CK_FMHA_DISABLE_BWD`) |
| `wheel` | `wheel_local_version` | Wheel `+local` tag (env `WHEEL_LOCAL_VERSION`; mapped to upstream `FLASH_ATTN_LOCAL_VERSION` at wheel time) |
| `wheel` | `wheel_artifact_name` | GitHub Actions artifact name |
| `release` | `release_tag_prefix` | Release tag prefix (`{prefix}-{variant}-build{run_number}`) |
| `release` | `release_title_prefix` | Release title prefix (env `RELEASE_TITLE_PREFIX`) |

`EXPECTED_WHEEL_PATTERN` is derived in `version-lock.ts` from `wheel.wheel_local_version` + `toolchain.python`, not stored in the lock file.

Prep clones **`flash_attention.build_commit`** (`fetch` + `checkout FETCH_HEAD`). `GPU_ARCHS` is read only from lock `compile.gpu_archs` (semicolon-separated on Windows).

### Supported GPUs (gfx120x / RDNA4)

| HIP ID | Die | Example models |
|--------|-----|----------------|
| **gfx1201** | Navi 48 | RX 9070 XT / RX 9070 / RX 9070 GRE; Radeon AI PRO R9700 series |
| **gfx1200** | Navi 44 | RX 9060 XT / RX 9060 / RX 9060 XT LP; RX 9050 series |

## Build profile

**Inference-only** wheel for ComfyUI (lock `compile.ck_disable_bwd=true`): fwd + fwd_appendkv + fwd_splitkv (no bwd when `CK_FMHA_DISABLE_BWD=1`), `-DFLASHATTENTION_DISABLE_BACKWARD` when bwd disabled, `cxx11.abi` local tag (see `wheel.wheel_local_version`), **`GPU_ARCHS`** from lock `compile.gpu_archs`, **`CK_OPT_DIM`** from lock `compile.ck_opt_dim` (mapped to upstream `OPT_DIM` env at compile time).

| Scope | Approx. ninja targets |
|-------|----------------------|
| Full link wheel (dual arch) | **~924** |
| Single OPT_DIM shard (dual arch) | **~218–288** |

> With `GPU_ARCHS=gfx1200;gfx1201`, hipcc emits code for both archs in one ninja rule per source file, so compile targets do **not** scale with arch count (CI logs show `[n/924]`).

## Trigger

| Workflow | Purpose | Trigger |
|----------|---------|---------|
| **Build FlashAttention CK serial (Windows gfx120x)** | Single-job full build + cache (`serial-v5`) | **Manual only** |
| **Build FlashAttention CK parallel (Windows gfx120x)** | OPT_DIM shard compile + link (`parallel-v5-d{dim}`) | **Manual only** |

Push to `main` does **not** auto-trigger builds.

**Manual inputs (both workflows):**

| Input | Default | Description |
|-------|---------|-------------|
| `ninja_workers` | `4` | Ninja parallel workers (use `2` if OOM) |
| `use_cache` | `true` | Set `false` to skip restore (still probes `exists`; `used=false`; cache still saved after a successful compile) |

### Serial (`build-fa2-ck-gfx120x-serial.yml`)

| Job | Role | Timeout |
|-----|------|---------|
| `compile-full-and-link` | clone+patch, toolchain, cache, `06.compile` + `08.wheel`, smoke test | 6 h |

### Parallel (`build-fa2-ck-gfx120x-parallel.yml`)

| Job | Role | Timeout |
|-----|------|---------|
| `plan-opt-dim` | export parallel OPT_DIM matrix | 15 min |
| `compile-d32` … `d256` | clone+patch per job, one OPT_DIM shard each, upload `.obj` | 6 h each |
| `link-wheel` | clone+patch, merge objs + link + wheel + CPU smoke test | 6 h |

Cache keys include `VERSION.lock.json` SHA256 prefix (`-v5-{lockHash8}-`) and three toolchain fingerprints (MSVC toolset / ROCm clang / pip toolchain); **exact match only** (no `restore-keys`). Serial: `fa2-ck-gfx120x-serial-v5-{lockHash8}-msvc{hash}-rocmClang{hash}-pipToolchain{hash}`; parallel: `fa2-ck-gfx120x-parallel-v5-{lockHash8}-d{dim}-msvc{hash}-rocmClang{hash}-pipToolchain{hash}`. Link uses **first lock `ck_opt_dim` tier** (`32`) for shared objs only.

Ninja cache is **saved only after a successful `06.compile`**; failed compiles never write cache (job timeout/cancellation likewise skips save). When a remote entry exists (`exists`) and compile succeeds, the stale entry is deleted before save refreshes it. `use_cache=false` skips restore (`used=false`); a successful compile still saves cache.

### Build stages

Single entry point for compile and wheel packaging: `build-fa-steps.py` (in-process `exec_module(setup.py)`), one of three `--step` modes:

| step | Role |
|------|------|
| `compile` | `build_ext` compile; stamps existing objects so the ninja cache pays off |
| `wheel` | stamp + `bdist_wheel` (objects from the in-place compile) |
| `merge-and-wheel` | merge objects + stamp + `bdist_wheel` (staging validation runs in `08.wheel` first) |

Serial and parallel compose the same entry; both produce identical wheels:

| Mode | Invocation sequence | OPT_DIM |
|------|---------------------|---------|
| Serial build | `--step compile` → `--step wheel` (no staging) | full |
| Parallel compile | `--step compile` (once per shard) | single shard |
| Parallel link | `--step merge-and-wheel` + staging | full (env) |

Env is set uniformly via `scripts/lib/init-build-env.ts` (includes `SOURCE_DATE_EPOCH` from `flash_attention.build_commit_date`).

## Output

Artifact: **`wheel_artifact_name`** — `.whl`, `.sha256`, `wheel.manifest.json`.

Under the same `VERSION.lock.json`, **serial and parallel should produce byte-identical wheels** (matching SHA256); `/Brepro` fixes PE TimeDateStamp, `SOURCE_DATE_EPOCH` fixes wheel zip metadata.

Expected wheel name (derived from `wheel.wheel_local_version` + `toolchain.python`):

```text
flash_attn-*+torch2.12.0.rocm7.14.0.cxx11.abi-cp312-cp312-win_amd64.whl
```

## Verification

| Check | Script |
|-------|--------|
| CI smoke test serial (CPU) | `npx tsx scripts/cli.ts 09.verify --dist-dir dist --build-variant serial --build-caches dist\build-caches.json` |
| CI smoke test parallel (CPU) | `npx tsx scripts/cli.ts 09.verify --dist-dir dist --build-variant parallel --build-caches cache-meta` |
| Parallel link API dispatch recompile checks | `build/build-fa-steps.py` (merge skip + pre/post ninja asserts) |
| Pre-deploy GPU smoke test (gfx120x hardware) | `python test/gpu-smoke-test.py -w .` |

Smoke test covers wheel structure, pip install, and extension import. Parallel link additionally asserts the three `fmha_*_api.obj` dispatch objects are skipped during merge and recompiled by ninja. GPU fwd + kvcache smoke is in `test/gpu-smoke-test.py` (run manually on gfx1200/gfx1201 hardware before deploy).

## ComfyUI install

```powershell
& "<ComfyUI>\python_embeded\python.exe" -m pip install .\downloaded.whl
```

Use launch arg `--use-flash-attention`.

See [AGENTS.md](AGENTS.md) for maintainer conventions.
