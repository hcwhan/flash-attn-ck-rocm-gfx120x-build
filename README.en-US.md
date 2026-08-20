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
| `flash_attention` | `repo`, `build_commit`, `build_commit_date` | Exact FA source cloned each build (`build_commit` may be a 40-char SHA or tag such as `v2.8.4`); **bump `build_commit` and `build_commit_date` when upgrading FA** |
| `flash_attention` | `min_commit` | Minimum RDNA4 gfx12x commit ([PR #2400](https://github.com/Dao-AILab/flash-attention/pull/2400)); **human-readable reference only** |
| `compile` | `gpu_archs`, `ck_opt_dim` | HIP compile targets (**sole arch source**), CK FMHA `opt_dim` tiers |
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

FlashAttention 2 CK wheel default build profile (workflow `ck_disable_bwd=false`, default):

- CK kernels: **fwd + fwd_appendkv + fwd_splitkv + bwd** (full build by default when `CK_DISABLE_BWD=false`; no bwd when `true`)
- **`-DFLASHATTENTION_DISABLE_BACKWARD`** (enabled only when `CK_DISABLE_BWD=true`)
- **C++11 ABI `cxx11.abi`** (matches pinned PyTorch; local tag see `wheel.wheel_local_version`)
- **`GPU_ARCHS`** = lock `compile.gpu_archs` (semicolon-separated on Windows)
- **`CK_OPT_DIM`** = lock `compile.ck_opt_dim` (currently `32,64,128,256`); `init-build-env.ts` maps to upstream `OPT_DIM` env

| `ck_disable_bwd` | Scope | Approx. ninja targets (dual arch, cold compile) | CI reference |
|------------------|-------|-----------------------------------------------|--------------|
| `false` (default, includes bwd) | Serial full compile | **1837** | serial build27 |
| `false` | Parallel single shard (d32 / d64 / d128 / d256) | **447 / 453 / 517 / 453** | parallel build23 (compile-d*) |
| `false` | Parallel link (API dispatch recompile) | **4** | parallel build23 |
| `true` (inference-only) | Parallel single shard (d32 / d64 / d128 / d256) | **192 / 200 / 272 / 204** | parallel build14 |
| `true` | Parallel link (API dispatch recompile) | **3** | parallel build14 |

> With `GPU_ARCHS=gfx1200;gfx1201`, hipcc emits code for both archs in one ninja rule per source file, so compile targets do **not** scale with arch count. In log lines `[n/N]`, **N** is the total ninja-graph target count; with a cache hit, N stays the same and only stale entries rebuild. Wheel size reference: full ~55 MB (build23), inference ~20 MB (build14).

## Trigger

| Workflow | Purpose | Trigger |
|----------|---------|---------|
| **Build FlashAttention CK serial (Windows gfx120x)** | Single-job full build + cache (`serial-v7`) | **Manual only** |
| **Build FlashAttention CK parallel (Windows gfx120x)** | OPT_DIM shard compile + link (table shorthand `parallel-v7`; full key includes `-dim[{shard}]`) | **Manual only** |

> Push to `main` does **not** auto-trigger builds.

**Manual inputs (both workflows):**

| Input | Default | Description |
|-------|---------|-------------|
| `ninja_workers` | `4` | Ninja parallel workers (use `2` if OOM) |
| `use_cache` | `true` | Set `false` to skip restore (still probes `exists`; `used=false`; save only after a successful compile) |
| `publish_release` | `true` | Set `false` to skip GitHub Release upload |
| `ck_disable_bwd` | `false` | Full build with bwd by default; set `true` to omit bwd codegen and enable `FLASHATTENTION_DISABLE_BACKWARD` (ComfyUI inference-only; smaller wheel, faster CI) |
| `retry_count` | `0` | Internal auto-retry counter; keep default on manual dispatch, **do not change** |

### Watchdog and auto-retry

GitHub-hosted runner jobs have a **6-hour** hard limit. A **5-hour** deadline starts at compile job step one (`watchdog/job-start`): on expiry, 5× SIGINT graceful abort → save ninja cache → `watchdog/dispatch-retry` auto dispatch (`retry_count` increments internally, default `0`, **give up at ≥8**; do not set manually).

| Condition | Behavior |
|-----------|----------|
| `use_cache=true` (default) | Save cache after abort and auto-retry |
| `use_cache=false` | No save on compile failure; **no** auto-retry |
| `taskkill` after 5× SIGINT | No save, no retry (`force-killed`) |

Wheel / verify / publish do not run unless compile succeeds. `wheel.manifest.json` `dispatch` records workflow snapshot including `retry_count` (see schema below). **Parallel** uses `07.evaluate-parallel-retry` + `dispatch-retry@main` from the `watchdog-retry` job when the compile matrix **fails**; **serial** calls `dispatch-retry@main` when `should-retry == true` (ordinary compile failure does not retry).

### Serial (`build-fa2-ck-gfx120x-serial.yml`)

| Job | Role | workflow timeout |
|-----|------|------------------|
| `compile-full-and-link-wheel` | job-start → **A00** → **A01** `watchdog/run` → `dispatch-retry` → `09.wheel` → **A99** | not set |

### Parallel (`build-fa2-ck-gfx120x-parallel.yml`)

| Job | Role | workflow timeout |
|-----|------|------------------|
| `plan-opt-dim` | checkout → **A00** (`step-prep-source=false`, `step-setup-toolchain=false`, `step-restore-ninja-cache=false`) → `02.plan-opt-dim-matrix` | **5 min** |
| `compile-d32` … `d256` | job-start → **A00** → **A01** → (success) `08.shard`, upload `compile-success-meta-d{dim}` and obj artifacts; (`aborted`) upload `watchdog-abort-meta-d{dim}` | not set |
| `watchdog-retry` | **A00** (lightweight) → download meta → `07.evaluate-parallel-retry` → `dispatch-retry` | not set |
| `link-wheel` | checkout → **A00** → download `d*` / `compile-success-meta-d*` → `09.wheel` → **A99** (**no** ninja cache) | not set |

> Except `plan-opt-dim`, workflows do **not** set `timeout-minutes`; “not set” means the GitHub hosted runner default **6 h** job limit applies. Compile jobs additionally use a **5 h** deadline from `watchdog/job-start` (see above). CI paths: `FA_SRC=C:\fa\flash-attention`; parallel also uses `FA_STAGING=C:\fa-staging`.

- **Ninja cache** (`flash-attention/build/` incremental compile; `hcwhan/actions/kit/cache@main`):
  - **family-key** (cleanup scope): serial `fa2-ck-gfx120x-serial-v7`; parallel `fa2-ck-gfx120x-parallel-v7-dim[{ck_opt_dim}]`
  - **cache-key** (lookup slot; actual GHA key = cache-key + UTC suffix): `{family}-lock[{lockHash8}]-bwd[{true|false}]-msvc[{msvcVersion}]-rocmClang[{rocmClangVersion}]-ninja[{ninjaMinor}]`
  - `lockHash8`: lock `toolchain`+`flash_attention`+`compile` → SHA256 prefix (8 hex chars; excludes `wheel`/`release`; excludes workflow `ck_disable_bwd`)
  - `bwd`: `fmha_bwd` (`true` = bwd kernels compiled; `false` = inference-only bwd omission)
  - `msvcVersion` / `rocmClangVersion`: full MSVC toolset version / parsed `clang --version` token (e.g. `14.44.35207`, `23.0.0git`); normalized via `cacheKeyToken` before entering the key
  - `ninja`: major.minor from `ninja --version`
  - restore (with `only-lookup`) picks the newest versioned key in the slot; save verifies via API + family cleanup; serial / parallel keys are **not shared**
  - With `use_cache=true`, cache is saved whenever the build step is not skipped; with `use_cache=false`, restore is skipped (`used=false`) and cache is saved only after a successful compile
- **Pip toolchain cache** (`PIP_TOOLCHAIN_CACHE_PREFIX` + `PIP_TOOLCHAIN_CACHE_KEY`): family `fa-pip-toolchain-v2`; key `fa-pip-toolchain-v2-py[{python}]-pt[{pytorch}]-dev[{torch_device_extra}]-rocm[{rocm}]-idx[{indexHash8}]` (`01.config`; `indexHash8` = lock `toolchain.rocm_index` → SHA256 prefix)
- All four shards compile shared objs; link uses only the **first lock `ck_opt_dim` tier** (currently `32`) for shared objs.

### Build stages

Single entry point for compile and wheel packaging: `build-fa-steps.py` (in-process `exec_module(setup.py)`), one of three `--step` modes:

| step | Role |
|------|------|
| `compile` | `build_ext` compile; stamps existing objects so the ninja cache pays off |
| `wheel` | stamp + `bdist_wheel` (objects from the in-place compile) |
| `merge-and-wheel` | merge objects + stamp + `bdist_wheel` (staging validation runs in `09.wheel` first) |

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
| serial | `flash-attn-ck-cp312-torch2.12.0-rocm7.14.0-gfx120x-serial-build27` | FlashAttention 2 CK gfx120x Windows (serial) 2026.08.10 19:00:00 |
| parallel | `flash-attn-ck-cp312-torch2.12.0-rocm7.14.0-gfx120x-parallel-build23` | FlashAttention 2 CK gfx120x Windows (parallel) 2026.08.10 19:00:00 |

- `flash_attn-*.whl`
- `flash_attn-*.whl.sha256`
- `wheel.manifest.json`

`wheel.manifest.json` is written by `10.verify` (uploaded in CI via `A99.verify-and-publish`). Key fields:

| Field | Meaning |
|-------|---------|
| `fmha_bwd` | Top-level; whether bwd kernels were compiled (`CK_DISABLE_BWD=false`) |
| `dispatch` | `ninja_workers`, `use_cache`, `ck_disable_bwd`, `retry_count` (workflow snapshot) |
| `build_meta[]` | Serial single entry / parallel four shards (`opt_dim` / `key` / `exists` / `used`) |

> Older manifests may use top-level `ck_disable_bwd` or cache keys with `*-v6` (no `bwd[...]` segment); treat current `10.verify` output as canonical. Samples under `dist/` may be from earlier CI runs.

```powershell
gh release list
gh release download flash-attn-ck-cp312-torch2.12.0-rocm7.14.0-gfx120x-serial-build27 -D .\dist
gh release download flash-attn-ck-cp312-torch2.12.0-rocm7.14.0-gfx120x-parallel-build23 -D .\dist
```

Expected wheel name (derived from `wheel.wheel_local_version` + `toolchain.python`; PEP 440 normalizes `-` and `_` to `.` in the local tag):

```text
flash_attn-*+ck.torch2.12.0.rocm7.14.0.gfx120x.cxx11.abi-cp312-cp312-win_amd64.whl
```

## Verification

| Check | Script |
|-------|--------|
| CI smoke test serial (CPU) | `npx tsx scripts/cli.ts 10.verify --dist-dir dist --build-variant serial --build-meta dist\compile-success-meta.json` |
| CI smoke test parallel (CPU) | `npx tsx scripts/cli.ts 10.verify --dist-dir dist --build-variant parallel --build-meta compile-success-meta` |
| Parallel link API dispatch recompile checks | `build/build-fa-steps.py` (merge skip + pre/post ninja asserts) |
| Pre-deploy GPU smoke test (gfx120x hardware) | `python test/gpu-smoke-test.py -w .` |

Smoke test: wheel filename/structure (.pyd size, METADATA) → pip install → import flash_attn_2_cuda; parallel link additionally asserts the API dispatch objects (3 fwd, plus `fmha_bwd_api.obj` when `CK_DISABLE_BWD=false`) are skipped during merge and recompiled by ninja. GPU fwd + kvcache + backward probe see `test/gpu-smoke-test.py` (run manually on gfx1200/gfx1201 hardware before deploy).

## ComfyUI install

```powershell
$PY = "<ComfyUI>\python_embeded\python.exe"
& $PY -m pip install .\downloaded.whl
```

ComfyUI diffusion inference only needs fwd; the default full wheel installs and runs as-is. When triggering CI yourself, check **`ck_disable_bwd=true`** for a shorter compile and smaller wheel (~20 MB vs ~55 MB; see parallel build14 / build23 in the table above).

Launch arg: `--use-flash-attention` (instead of `--use-pytorch-cross-attention`).

See [AGENTS.md](AGENTS.md) for maintainer conventions. License: [MIT](LICENSE).
