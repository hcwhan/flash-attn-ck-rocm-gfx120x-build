# flash-attn-ck-rocm-gfx120x-build

[English](README.en-US.md)

使用 GitHub Actions 为 **Windows / gfx120x（RDNA4）/ PyTorch 2.12.0+rocm7.14.0** 编译 **FlashAttention 2 CK 后端** wheel。

工具链版本以 **`VERSION.lock.json`** 为唯一来源，经 workflow 内 `npx tsx scripts/cli.ts 01.config -w $env:GITHUB_WORKSPACE --export-github-env` 注入 CI。

## 目标环境

| 项 | 值 |
|----|-----|
| GPU 架构 | lock **`compile.gpu_archs`**（当前 `gfx1200;gfx1201`） |
| 系统 | Windows |
| Python | 3.12 |
| PyTorch | `2.12.0+rocm7.14.0` |
| flash-attention | `VERSION.lock.json` **`flash_attention.build_commit`** |
| Runner | `windows-2022`（GitHub 托管） |
| Node.js | >= 26（CI bootstrap；本地可用 `npm run fa -- <cmd>`） |

### `VERSION.lock.json` 分组

| 分组 | 字段 | 作用 |
|------|------|------|
| `toolchain` | `python`、`pytorch`、`torch_device_extra`、`rocm_index`、`rocm` | pip 工具链 pin |
| `flash_attention` | `repo`、`build_commit`、`build_commit_date` | 每次构建精确 clone 的 FA 源码（`build_commit` 可为 40 位 SHA 或 tag，如 `v2.8.4`）；**升级 FA 时改 `build_commit` 与 `build_commit_date`** |
| `flash_attention` | `min_commit` | RDNA4 gfx12x 最低要求 commit（[PR #2400](https://github.com/Dao-AILab/flash-attention/pull/2400)）；**仅人类可读参考** |
| `compile` | `gpu_archs`、`ck_opt_dim` | HIP 编译目标（**唯一架构源**）、CK FMHA `opt_dim` 档位 |
| `wheel` | `wheel_local_version` | wheel 的 `+local` 标签（env `WHEEL_LOCAL_VERSION`；wheel 时映射 upstream `FLASH_ATTN_LOCAL_VERSION`） |
| `wheel` | `wheel_artifact_name` | GitHub Actions artifact 名称 |
| `release` | `release_tag_prefix` | Release tag 前缀（`{prefix}-{variant}-build{run_number}`） |
| `release` | `release_title_prefix` | Release 标题前缀（env `RELEASE_TITLE_PREFIX`；GitHub Release name = `{prefix} (serial\|parallel) YYYY.MM.DD HH:mm:ss`，Asia/Shanghai） |

`EXPECTED_WHEEL_PATTERN` 由 `wheel.wheel_local_version` + `toolchain.python` 在 `version-lock.ts` 推导，不在 lock 中存储。

规则：CI 始终 clone **`flash_attention.build_commit`**（SHA 或 tag；`fetch origin <ref>` + `checkout FETCH_HEAD`）；`GPU_ARCHS` 只从 lock `compile.gpu_archs` 读取（Windows 分号分隔）。

### 适用显卡（gfx120x / RDNA4）

| HIP 代号 | 芯片 | 代表型号 |
|----------|------|----------|
| **gfx1201** | Navi 48 | RX 9070 XT / RX 9070 / RX 9070 GRE；Radeon AI PRO R9700 系列 |
| **gfx1200** | Navi 44 | RX 9060 XT / RX 9060 / RX 9060 XT LP；RX 9050 系列 |

## 编译配置

FlashAttention 2 CK wheel 构建配置（workflow `ck_disable_bwd=false`，默认）：

- CK 内核：**fwd + fwd_appendkv + fwd_splitkv + bwd**（`CK_FMHA_DISABLE_BWD=0` 默认完整编译；设为 `1` 时无 bwd）
- **`-DFLASHATTENTION_DISABLE_BACKWARD`**（仅 `CK_FMHA_DISABLE_BWD=1` 时启用）
- **C++11 ABI `cxx11.abi`**（与 pin 的 PyTorch 一致；local tag 见 `wheel.wheel_local_version`）
- **`GPU_ARCHS`** = lock `compile.gpu_archs`（Windows 分号分隔）
- **`CK_OPT_DIM`** = lock `compile.ck_opt_dim`（当前 `32,64,128,256`）；`init-build-env.ts` 映射为 upstream `OPT_DIM` env

| `ck_disable_bwd` | 范围 | 约计 ninja targets（双 arch，cold compile） | CI 参考 |
|------------------|------|-------------------------------------------|---------|
| `false`（默认，含 bwd） | 串行全量 compile | **1837** | serial build27 |
| `false` | parallel 单 shard（d32 / d64 / d128 / d256） | **447 / 453 / 517 / 453** | parallel build23（compile-d*） |
| `false` | parallel link（API dispatch 重编） | **4** | parallel build23 |
| `true`（推理专用） | parallel 单 shard（d32 / d64 / d128 / d256） | **192 / 200 / 272 / 204** | parallel build14 |
| `true` | parallel link（API dispatch 重编） | **3** | parallel build14 |

> `GPU_ARCHS=gfx1200;gfx1201` 时 hipcc 在同一 ninja rule 内为两个 arch 生成代码，**不会**按 arch 数量倍增 compile targets。日志 `[n/N]` 中 **N** 为 ninja 图总 target 数；ninja cache 命中时 N 不变、仅重建过期条目。wheel 体积参考：full ~55 MB（build23），inference ~20 MB（build14）。

## 触发方式

| Workflow | 用途 | 触发 |
|----------|------|------|
| **Build FlashAttention CK serial (Windows gfx120x)** | 单 job 全量编译 + cache（`serial-v7`） | **仅手动** |
| **Build FlashAttention CK parallel (Windows gfx120x)** | OPT_DIM 分片 compile + link（表格简称 `parallel-v7`；完整 key 含 `-dim[{shard}]`） | **仅手动** |

> 推送到 `main` **不会**自动触发编译。

**手动输入（两个 workflow 均有）：**

| 输入 | 默认 | 说明 |
|------|------|------|
| `ninja_workers` | `4` | Ninja 并行 worker 数（OOM 时可改为 `2`） |
| `use_cache` | `true` | 设为 `false` 时不 restore（仍 lookup 探测 `exists`；`used=false`；仅 compile 成功时 save） |
| `publish_release` | `true` | 设为 `false` 时跳过 GitHub Release 上传 |
| `ck_disable_bwd` | `false` | 默认完整编译含 bwd；设为 `true` 时省略 bwd codegen 并启用 `FLASHATTENTION_DISABLE_BACKWARD`（ComfyUI 推理专用，wheel 更小、CI 更快） |
| `retry_count` | `0` | 看门狗 auto-retry 内部递增；手动触发时保持默认，**勿改** |

### 看门狗与自动 retry

GitHub-hosted runner 的 job 硬上限为 **6 小时**。compile 自 A00 bootstrap 第一步起算 **5 小时**看门狗：到期后 3× SIGINT 优雅中断 → save ninja cache → 自动 dispatch retry（`retry_count` 内部递增，默认 `0`，**≥8 放弃**；手动触发时无需填写）。

| 条件 | 行为 |
|------|------|
| `use_cache=true`（默认） | 中断后 save cache 并 auto-retry |
| `use_cache=false` | compile 失败时不 save；**不** auto-retry |
| 3× SIGINT 后需 `taskkill` | 不 save、不 retry（`ABORT_FORCE_KILLED`） |

wheel / verify / publish 在 compile 未成功时不运行。`wheel.manifest.json` 的 `dispatch` 含 `retry_count` 等 workflow 快照（见下文 schema）。**parallel** 在 compile matrix **失败**且全部 shard 结束后，由独立 `watchdog-retry` job 调用 `07-retry`（失败 shard 上传 artifact `abort-meta-d{dim}`，文件 `abort-meta/d{dim}.json`）；**serial** 在 compile job 内看门狗中止时 `07-retry`（普通 compile 失败不 retry）。详见 [docs/watchdog-design.md](docs/watchdog-design.md)。

### 串行（`build-fa2-ck-gfx120x-serial.yml`）

| Job | 作用 | workflow 超时 |
|-----|------|---------------|
| `compile-full-and-link-wheel` | checkout → **A00**（含 ninja restore）→ **A01** `06.compile`（看门狗中止时 `07-retry`）→ `dist/build-caches.json`（成功）→ `09.wheel` → **A99** | 未设 |

### 并行（`build-fa2-ck-gfx120x-parallel.yml`）

| Job | 作用 | workflow 超时 |
|-----|------|---------------|
| `plan-opt-dim` | checkout → **A00**（`prep-source=false`, `setup-toolchain=false`）→ `02.plan-opt-dim-matrix` | **5 min** |
| `compile-d32` … `d256` | checkout → **A00** → **A01** `06.compile` →（成功）`08.shard`、上传 `d{dim}` / `cache-meta-d{dim}`；（看门狗失败）上传 `abort-meta-d{dim}` | 未设 |
| `watchdog-retry` | checkout → **A00**（`prep-source=false`, `setup-toolchain=false`）→ `07-retry` | 未设 |
| `link-wheel` | checkout → **A00** → download `d*` / `cache-meta-d*` → `09.wheel` → **A99**（**无** ninja cache） | 未设 |

> 除 `plan-opt-dim` 外 workflow **未**显式设 `timeout-minutes`；「未设」表示使用 GitHub hosted runner 默认 **6 h** job 上限。compile job 另有自 A00 第一步起算的 **5 h** 看门狗（见上文）。CI 路径：`FA_SRC=C:\fa\flash-attention`；parallel 另设 `FA_STAGING=C:\fa-staging`。

- **Ninja cache**（`flash-attention/build/` 增量编译；`hcwhan/actions/cache@main`）：
  - **family-key**（同族 cleanup 范围）：串行 `fa2-ck-gfx120x-serial-v7`；并行 `fa2-ck-gfx120x-parallel-v7-dim[{ck_opt_dim}]`
  - **cache-key**（lookup 槽位；实际 GHA key = cache-key + UTC 后缀）：`{family}-lock[{lockHash8}]-bwd[{true|false}]-msvc[{msvcVersion}]-rocmClang[{rocmClangVersion}]-ninja[{ninjaMinor}]`
  - `lockHash8`：lock `toolchain`+`flash_attention`+`compile` → SHA256 前 8 位（不含 `wheel`/`release`；不含 workflow `ck_disable_bwd`）
  - `bwd`：`fmha_bwd`（`true` = 编译 bwd 内核；`false` = 推理专用省略 bwd）
  - `msvcVersion` / `rocmClangVersion`：MSVC 工具集完整版本 / `clang --version` 解析完整版本（如 `14.44.35207`、`23.0.0git`）；写入 key 前经 `cacheKeyToken` 规范化
  - `ninja`：`ninja --version` 的 major.minor
  - restore/lookup 取槽位最新 versioned key；save 后 API verify + 同族 cleanup；serial / parallel **互不共用**
  - `use_cache=true` 时 build 非 skipped 即 save；`use_cache=false` 时不 restore（`used=false`），仅 compile 成功时 save
- **Pip toolchain cache**（`PIP_TOOLCHAIN_CACHE_PREFIX` + `PIP_TOOLCHAIN_CACHE_KEY`）：family `fa-pip-toolchain-v2`；key `fa-pip-toolchain-v2-py[{python}]-pt[{pytorch}]-dev[{torch_device_extra}]-rocm[{rocm}]-idx[{indexHash8}]`（`01.config`；`indexHash8` = lock `toolchain.rocm_index` → SHA256 前 8 位）
- 四 shard 各编 shared obj；link 仅使用 **lock `ck_opt_dim` 第一档**（当前 `32`）的 shared obj。

### 构建阶段

编译/打 wheel 唯一入口：`build-fa-steps.py`（同进程 `exec_module(setup.py)`），按 `--step` 三选一：

| step | 作用 |
|------|------|
| `compile` | `build_ext` 编译；stamp 已有对象，让 ninja 缓存生效 |
| `wheel` | stamp + `bdist_wheel`（对象来自原地编译） |
| `merge-and-wheel` | merge 对象 + stamp + `bdist_wheel`（staging 校验在 `09.wheel` 前置） |

串行 / 并行共用同一入口编排，产物相同：

| 模式 | 调用序列 | OPT_DIM |
|------|---------|---------|
| 串行 build | `--step compile` → `--step wheel`（无 staging） | 全量 |
| 并行 compile | `--step compile`（每 shard 一次） | 单 shard |
| 并行 link | `--step merge-and-wheel` + staging | 全量（env） |

env 统一经 `scripts/lib/init-build-env.ts`（含 `SOURCE_DATE_EPOCH`，取自 `flash_attention.build_commit_date`）。

## 产物

Artifact：**`wheel_artifact_name`**（Actions 短期下载）

同一 `VERSION.lock.json` 下，**serial / parallel 应产出 byte-identical wheel**（SHA256 一致）；`/Brepro` 固定 PE TimeDateStamp，`SOURCE_DATE_EPOCH` 固定 wheel zip。

GitHub Release（构建成功后自动上传；serial / parallel 使用不同 tag；标题格式 `{prefix} (serial|parallel) YYYY.MM.DD HH:mm:ss`，Asia/Shanghai）：

| Workflow | Tag 示例 | Release 标题示例 |
|----------|----------|------------------|
| serial | `flash-attn-ck-cp312-torch2.12.0-rocm7.14.0-gfx120x-serial-build27` | FlashAttention 2 CK gfx120x Windows (serial) 2026.08.10 19:00:00 |
| parallel | `flash-attn-ck-cp312-torch2.12.0-rocm7.14.0-gfx120x-parallel-build23` | FlashAttention 2 CK gfx120x Windows (parallel) 2026.08.10 19:00:00 |

- `flash_attn-*.whl`
- `flash_attn-*.whl.sha256`
- `wheel.manifest.json`

`wheel.manifest.json` 由 `10.verify` 写入（CI 经 `A99.fa-verify-publish` 上传）。主要字段：

| 字段 | 含义 |
|------|------|
| `fmha_bwd` | 顶层；是否编译 bwd 内核（=`CK_FMHA_DISABLE_BWD=0`） |
| `dispatch` | `ninja_workers`、`use_cache`、`ck_disable_bwd`、`retry_count`（workflow 快照） |
| `build_caches[]` | serial 单条 / parallel 四 shard（`opt_dim` / `key` / `exists` / `used`） |

> 旧版 manifest 可能在顶层使用 `ck_disable_bwd`，或 cache key 为 `*-v6`（无 `bwd[...]` 段）；以当前 `10.verify` 输出为准。`dist/` 内样例可能来自较早 CI run。

```powershell
gh release list
gh release download flash-attn-ck-cp312-torch2.12.0-rocm7.14.0-gfx120x-serial-build27 -D .\dist
gh release download flash-attn-ck-cp312-torch2.12.0-rocm7.14.0-gfx120x-parallel-build23 -D .\dist
```

预期 wheel 文件名（由 `wheel.wheel_local_version` + `toolchain.python` 推导；PEP 440 将 local tag 中的 `-`、`_` 规范化为 `.`）：

```text
flash_attn-*+ck.torch2.12.0.rocm7.14.0.gfx120x.cxx11.abi-cp312-cp312-win_amd64.whl
```

## 验证

| 检查 | 脚本 |
|------|------|
| CI smoke test serial（CPU） | `npx tsx scripts/cli.ts 10.verify --dist-dir dist --build-variant serial --build-caches dist\build-caches.json` |
| CI smoke test parallel（CPU） | `npx tsx scripts/cli.ts 10.verify --dist-dir dist --build-variant parallel --build-caches cache-meta` |
| parallel link API dispatch 重编校验 | `build/build-fa-steps.py`（merge skip + ninja 前后断言） |
| 部署前 GPU smoke test（gfx120x 真机） | `python test/gpu-smoke-test.py -w .` |

Smoke test：wheel 文件名/结构（.pyd 体积、METADATA）→ pip 安装 → import flash_attn_2_cuda；parallel link 另在 merge 阶段断言 API dispatch 对象（fwd 3 个，`CK_FMHA_DISABLE_BWD=0` 时再加 `fmha_bwd_api.obj`）被 skip 并由 ninja 重编。GPU fwd + kvcache + backward 探测见 `test/gpu-smoke-test.py`（部署前在 gfx1200/gfx1201 真机手动跑）。

## 安装到 ComfyUI

```powershell
$PY = "<ComfyUI>\python_embeded\python.exe"
& $PY -m pip install .\downloaded.whl
```

ComfyUI 扩散推理只需 fwd，默认 full wheel 可直接安装使用。若自行触发 CI 构建，手动勾选 **`ck_disable_bwd=true`** 可缩短编译并减小 wheel（约 20 MB vs ~55 MB；见上表 parallel build14 / build23）。

启动参数：`--use-flash-attention`（替代 `--use-pytorch-cross-attention`）。

更多维护约定见 [AGENTS.md](AGENTS.md)。许可证：[MIT](LICENSE)。
