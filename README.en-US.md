# flash-attn-ck-rocm-gfx120x-build

[中文](README.md)

GitHub Actions workflow to build **FlashAttention 2 CK backend** for **Windows / gfx120x (RDNA4) / PyTorch 2.12.0+rocm7.14.0**.

Toolchain versions are pinned in **`VERSION.lock.json`** and loaded via `npx tsx scripts/cli.ts 01.config -w $env:GITHUB_WORKSPACE --export-github-env` in each workflow job.

## Target environment

| Item | Value |
|------|-------|
| GPU arch | lock **`compile.gpu_archs`** (currently `gfx1200;gfx1201`) |
| OS | Windows |
| Python | 3.12 |
| PyTorch | `2.12.0+rocm7.14.0` |
| flash-attention | `VERSION.lock.json` **`flash_attention.build_commit`** |
| Runner | `windows-2022` (hosted) |
| Node.js | >= 26 (CI bootstrap; locally use `npm run fa -- <cmd>`) |

### `VERSION.lock.json` sections

| Section | Field | Role |
|---------|-------|------|
| `toolchain` | `python`, `pytorch`, `torch_device_extra`, `rocm_index`, `rocm` | pip toolchain pins |
| `flash_attention` | `repo`, `build_commit`, `build_commit_date` | Exact FA source cloned each build (`build_commit` may be a 40-char SHA or tag such as `v2.7.4.post1`); **bump `build_commit` and `build_commit_date` when upgrading FA** |
| `flash_attention` | `min_commit` | Minimum RDNA4 gfx12x commit ([PR #2400](https://github.com/Dao-AILab/flash-attention/pull/2400)); **human-readable reference only** |
| `compile` | `gpu_archs`, `ck_opt_dim`, `ck_disable_bwd` | HIP compile targets (**sole arch source**), CK FMHA `opt_dim` tiers, and whether bwd is omitted (`CK_FMHA_DISABLE_BWD`) |
| `wheel` | `wheel_local_version` | Wheel `+local` tag (env `WHEEL_LOCAL_VERSION`; mapped to upstream `FLASH_ATTN_LOCAL_VERSION` at wheel time) |
| `wheel` | `wheel_artifact_name` | GitHub Actions artifact name |
| `release` | `release_tag_prefix` | Release tag prefix (`{prefix}-{variant}-build{run_number}`) |
| `release` | `release_title_prefix` | Release title prefix (env `RELEASE_TITLE_PREFIX`; GitHub Release name = `{prefix} (serial\|parallel) YYYY.MM.DD HH:mm:ss`, Asia/Shanghai) |

`EXPECTED_WHEEL_PATTERN` is derived in `version-lock.ts` from `wheel.wheel_local_version` + `toolchain.python`, not stored in the lock file.

Prep clones **`flash_attention.build_commit`** (SHA or tag; `fetch origin <ref>` + `checkout FETCH_HEAD`). `GPU_ARCHS` is read only from lock `compile.gpu_archs` (semicolon-separated on Windows).

### Supported GPUs (gfx120x / RDNA4)

| HIP ID | Die | Example models |
|--------|-----|----------------|
| **gfx1201** | Navi 48 | RX 9070 XT / RX 9070 / RX 9070 GRE; Radeon AI PRO R9700 series |
| **gfx1200** | Navi 44 | RX 9060 XT / RX 9060 / RX 9060 XT LP; RX 9050 series |

## Build profile

ComfyUI **inference-only** wheel (lock `compile.ck_disable_bwd=true`):

- CK kernels: **fwd + fwd_appendkv + fwd_splitkv** (no bwd when `CK_FMHA_DISABLE_BWD=1`)
- **`-DFLASHATTENTION_DISABLE_BACKWARD`** (enabled when `CK_FMHA_DISABLE_BWD=1`)
- **C++11 ABI `cxx11.abi`** (matches pinned PyTorch; local tag see `wheel.wheel_local_version`)
- **`GPU_ARCHS`** = lock `compile.gpu_archs` (semicolon-separated on Windows)
- **`CK_OPT_DIM`** = lock `compile.ck_opt_dim` (currently `32,64,128,256`); `init-build-env.ts` maps to upstream `OPT_DIM` env

| Scope | Approx. ninja targets |
|-------|----------------------|
| Full link wheel (dual arch) | **~924** |
| Single OPT_DIM shard (dual arch) | **~218–288** |

> With `GPU_ARCHS=gfx1200;gfx1201`, hipcc emits code for both archs in one ninja rule per source file, so compile targets do **not** scale with arch count (CI logs show `[n/924]`).

## Trigger

| Workflow | Purpose | Trigger |
|----------|---------|---------|
| **Build FlashAttention CK serial (Windows gfx120x)** | Single-job full build + cache (`serial-v6`) | **Manual only** |
| **Build FlashAttention CK parallel (Windows gfx120x)** | OPT_DIM shard compile + link (table shorthand `parallel-v6`; full key includes `-dim[{shard}]`) | **Manual only** |

> Push to `main` does **not** auto-trigger builds.

**Manual inputs (both workflows):**

| Input | Default | Description |
|-------|---------|-------------|
| `ninja_workers` | `4` | Ninja parallel workers (use `2` if OOM) |
| `use_cache` | `true` | Set `false` to skip restore (still probes `exists`; `used=false`; save only after a successful compile) |
| `publish_release` | `true` | Set `false` to skip GitHub Release upload |

### Serial (`build-fa2-ck-gfx120x-serial.yml`)

| Job | Role | Timeout |
|-----|------|---------|
| `compile-full-and-link-wheel` | clone+patch, toolchain, cache, `06.compile` + `08.wheel`, CPU smoke test | 6 h (default) |

### Parallel (`build-fa2-ck-gfx120x-parallel.yml`)

| Job | Role | Timeout |
|-----|------|---------|
| `plan-opt-dim` | export parallel OPT_DIM matrix | 5 min |
| `compile-d32` … `d256` | clone+patch per job, one OPT_DIM shard each, upload `.obj` | 6 h each (default) |
| `link-wheel` | clone+patch, merge objs + link + wheel + CPU smoke test (**no** ninja cache) | 6 h (default) |

> Except `plan-opt-dim`, workflows do not set `timeout-minutes`; “6 h (default)” is the GitHub hosted runner limit. CI paths: `FA_SRC=C:\fa\flash-attention`; parallel also uses `FA_STAGING=C:\fa-staging`.

- **Ninja cache** (`flash-attention/build/` incremental compile):
  - Serial: `fa2-ck-gfx120x-serial-v6-lock[{lockHash8}]-msvc[{msvcVersion}]-rocmClang[{rocmClangVersion}]-ninja[{ninjaMinor}]`
  - Parallel: `fa2-ck-gfx120x-parallel-v6-lock[{lockHash8}]-dim[{ck_opt_dim}]-msvc[{msvcVersion}]-rocmClang[{rocmClangVersion}]-ninja[{ninjaMinor}]`
  - `lockHash8`: lock `toolchain`+`flash_attention`+`compile` → SHA256 prefix (8 hex chars; excludes `wheel`/`release`)
  - `msvcVersion` / `rocmClangVersion`: full MSVC toolset version / parsed `clang --version` token (e.g. `14.42.34433`, `19.0.0git`); normalized via `cacheKeyToken` before entering the key
  - `ninja`: major.minor from `ninja --version`
  - **Exact match only** (no `restore-keys`); serial / parallel keys are **not shared**
  - With `use_cache=true`, cache is saved whenever the build step is not skipped; with `use_cache=false`, restore is skipped (`used=false`) and cache is saved only after a successful compile. When a remote entry exists (`exists`), it is deleted before save refreshes it.
- **Pip toolchain cache** (`PIP_TOOLCHAIN_CACHE_KEY`): `fa-pip-toolchain-v2-py[{python}]-pt[{pytorch}]-dev[{torch_device_extra}]-rocm[{rocm}]-idx[{indexHash8}]` (`01.config`; `indexHash8` = lock `toolchain.rocm_index` → SHA256 prefix)
- All four shards compile shared objs; link uses only the **first lock `ck_opt_dim` tier** (currently `32`) for shared objs.

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

Artifact: **`wheel_artifact_name`** (short-term Actions download)

Under the same `VERSION.lock.json`, **serial and parallel should produce byte-identical wheels** (matching SHA256); `/Brepro` fixes PE TimeDateStamp, `SOURCE_DATE_EPOCH` fixes wheel zip metadata.

GitHub Release (uploaded automatically after a successful build; serial / parallel use different tags; title format `{prefix} (serial|parallel) YYYY.MM.DD HH:mm:ss`, Asia/Shanghai):

| Workflow | Tag example | Release title example |
|----------|-------------|----------------------|
| serial | `flash-attn-ck-cp312-torch2.12.0-rocm7.14.0-gfx120x-serial-build123` | FlashAttention 2 CK gfx120x Windows (serial) 2026.08.10 19:00:00 |
| parallel | `flash-attn-ck-cp312-torch2.12.0-rocm7.14.0-gfx120x-parallel-build123` | FlashAttention 2 CK gfx120x Windows (parallel) 2026.08.10 19:00:00 |

- `flash_attn-*.whl`
- `flash_attn-*.whl.sha256`
- `wheel.manifest.json`

```powershell
gh release list
gh release download flash-attn-ck-cp312-torch2.12.0-rocm7.14.0-gfx120x-serial-build123 -D .\dist
gh release download flash-attn-ck-cp312-torch2.12.0-rocm7.14.0-gfx120x-parallel-build123 -D .\dist
```

Expected wheel name (derived from `wheel.wheel_local_version` + `toolchain.python`; PEP 440 normalizes `-` and `_` to `.` in the local tag):

```text
flash_attn-*+ck.torch2.12.0.rocm7.14.0.gfx120x.cxx11.abi-cp312-cp312-win_amd64.whl
```

## Verification

| Check | Script |
|-------|--------|
| CI smoke test serial (CPU) | `npx tsx scripts/cli.ts 09.verify --dist-dir dist --build-variant serial --build-caches dist\build-caches.json` |
| CI smoke test parallel (CPU) | `npx tsx scripts/cli.ts 09.verify --dist-dir dist --build-variant parallel --build-caches cache-meta` |
| Parallel link API dispatch recompile checks | `build/build-fa-steps.py` (merge skip + pre/post ninja asserts) |
| Pre-deploy GPU smoke test (gfx120x hardware) | `python test/gpu-smoke-test.py -w .` |

Smoke test: wheel filename/structure (.pyd size, OPT_DIM kernel symbols, METADATA) → pip install → import flash_attn_2_cuda; parallel link additionally asserts the three `fmha_*_api.obj` dispatch objects are skipped during merge and recompiled by ninja. GPU fwd + kvcache see `test/gpu-smoke-test.py` (run manually on gfx1200/gfx1201 hardware before deploy).

## ComfyUI install

```powershell
$PY = "<ComfyUI>\python_embeded\python.exe"
& $PY -m pip install .\downloaded.whl
```

Launch arg: `--use-flash-attention` (instead of `--use-pytorch-cross-attention`).

See [AGENTS.md](AGENTS.md) for maintainer conventions. License: [MIT](LICENSE).
