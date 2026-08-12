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
| `flash_attention` | `repo`、`build_commit`、`build_commit_date` | 每次构建精确 clone 的 FA 源码（`build_commit` 可为 40 位 SHA 或 tag，如 `v2.7.4.post1`）；**升级 FA 时改 `build_commit` 与 `build_commit_date`** |
| `flash_attention` | `min_commit` | RDNA4 gfx12x 最低要求 commit（[PR #2400](https://github.com/Dao-AILab/flash-attention/pull/2400)）；**仅人类可读参考** |
| `compile` | `gpu_archs`、`ck_opt_dim`、`ck_disable_bwd` | HIP 编译目标（**唯一架构源**）、CK FMHA `opt_dim` 档位、是否省略 bwd（`CK_FMHA_DISABLE_BWD`） |
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

ComfyUI **推理专用** wheel（lock `compile.ck_disable_bwd=true`）：

- CK 内核：**fwd + fwd_appendkv + fwd_splitkv**（`CK_FMHA_DISABLE_BWD=1` 时无 bwd）
- **`-DFLASHATTENTION_DISABLE_BACKWARD`**（`CK_FMHA_DISABLE_BWD=1` 时启用）
- **C++11 ABI `cxx11.abi`**（与 pin 的 PyTorch 一致；local tag 见 `wheel.wheel_local_version`）
- **`GPU_ARCHS`** = lock `compile.gpu_archs`（Windows 分号分隔）
- **`CK_OPT_DIM`** = lock `compile.ck_opt_dim`（当前 `32,64,128,256`）；`init-build-env.ts` 映射为 upstream `OPT_DIM` env

| 范围 | 约计 ninja targets |
|------|-------------------|
| link 汇总全量（双 arch） | **~924** |
| 单 OPT_DIM shard（双 arch） | **~218–288** |

> `GPU_ARCHS=gfx1200;gfx1201` 时 hipcc 在同一 ninja rule 内为两个 arch 生成代码，**不会**按 arch 数量倍增 compile targets（CI 日志中可见 `[n/924]`）。

## 触发方式

| Workflow | 用途 | 触发 |
|----------|------|------|
| **Build FlashAttention CK serial (Windows gfx120x)** | 单 job 全量编译 + cache（`serial-v6`） | **仅手动** |
| **Build FlashAttention CK parallel (Windows gfx120x)** | OPT_DIM 分片 compile + link（表格简称 `parallel-v6`；完整 key 含 `-dim[{shard}]`） | **仅手动** |

> 推送到 `main` **不会**自动触发编译。

**手动输入（两个 workflow 均有）：**

| 输入 | 默认 | 说明 |
|------|------|------|
| `ninja_workers` | `4` | Ninja 并行 worker 数（OOM 时可改为 `2`） |
| `use_cache` | `true` | 设为 `false` 时不 restore（仍 lookup 探测 `exists`；`used=false`；仅 compile 成功时 save） |
| `publish_release` | `true` | 设为 `false` 时跳过 GitHub Release 上传 |

### 串行（`build-fa2-ck-gfx120x-serial.yml`）

| Job | 作用 | 超时 |
|-----|------|------|
| `compile-full-and-link-wheel` | clone+patch、toolchain、cache、`06.compile` + `08.wheel`、CPU smoke test | 6 h（默认） |

### 并行（`build-fa2-ck-gfx120x-parallel.yml`）

| Job | 作用 | 超时 |
|-----|------|------|
| `plan-opt-dim` | 导出 parallel OPT_DIM matrix | 5 min |
| `compile-d32` … `d256` | 各 job 内 clone+patch，编一个 OPT_DIM shard，上传 `.obj` | 各 6 h（默认） |
| `link-wheel` | clone+patch、合并 obj + link + 打 wheel + CPU smoke test（**无** ninja cache） | 6 h（默认） |

> 除 `plan-opt-dim` 外 workflow 未显式设 `timeout-minutes`；「6 h（默认）」为 GitHub hosted runner 上限。CI 路径：`FA_SRC=C:\fa\flash-attention`；parallel 另设 `FA_STAGING=C:\fa-staging`。

- **Ninja cache**（`flash-attention/build/` 增量编译）：
  - 串行：`fa2-ck-gfx120x-serial-v6-lock[{lockHash8}]-msvc[{msvcVersion}]-rocmClang[{rocmClangVersion}]-ninja[{ninjaMinor}]`
  - 并行：`fa2-ck-gfx120x-parallel-v6-lock[{lockHash8}]-dim[{ck_opt_dim}]-msvc[{msvcVersion}]-rocmClang[{rocmClangVersion}]-ninja[{ninjaMinor}]`
  - `lockHash8`：lock `toolchain`+`flash_attention`+`compile` → SHA256 前 8 位（不含 `wheel`/`release`）
  - `msvcVersion` / `rocmClangVersion`：MSVC 工具集完整版本 / `clang --version` 解析完整版本（如 `14.42.34433`、`19.0.0git`）；写入 key 前经 `cacheKeyToken` 规范化
  - `ninja`：`ninja --version` 的 major.minor
  - **仅精确匹配**（无 `restore-keys`）；serial / parallel **互不共用**
  - `use_cache=true` 时 build 非 skipped 即 save；`use_cache=false` 时不 restore（`used=false`），仅 compile 成功时 save；远端已有条目（`exists`）时 save 前先 delete 再刷新
- **Pip toolchain cache**（`PIP_TOOLCHAIN_CACHE_KEY`）：`fa-pip-toolchain-v2-py[{python}]-pt[{pytorch}]-dev[{torch_device_extra}]-rocm[{rocm}]-idx[{indexHash8}]`（`01.config`；`indexHash8` = lock `toolchain.rocm_index` → SHA256 前 8 位）
- 四 shard 各编 shared obj；link 仅使用 **lock `ck_opt_dim` 第一档**（当前 `32`）的 shared obj。

### 构建阶段

编译/打 wheel 唯一入口：`build-fa-steps.py`（同进程 `exec_module(setup.py)`），按 `--step` 三选一：

| step | 作用 |
|------|------|
| `compile` | `build_ext` 编译；stamp 已有对象，让 ninja 缓存生效 |
| `wheel` | stamp + `bdist_wheel`（对象来自原地编译） |
| `merge-and-wheel` | merge 对象 + stamp + `bdist_wheel`（staging 校验在 `08.wheel` 前置） |

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

预期 wheel 文件名（由 `wheel.wheel_local_version` + `toolchain.python` 推导；PEP 440 将 local tag 中的 `-`、`_` 规范化为 `.`）：

```text
flash_attn-*+ck.torch2.12.0.rocm7.14.0.gfx120x.cxx11.abi-cp312-cp312-win_amd64.whl
```

## 验证

| 检查 | 脚本 |
|------|------|
| CI smoke test serial（CPU） | `npx tsx scripts/cli.ts 09.verify --dist-dir dist --build-variant serial --build-caches dist\build-caches.json` |
| CI smoke test parallel（CPU） | `npx tsx scripts/cli.ts 09.verify --dist-dir dist --build-variant parallel --build-caches cache-meta` |
| parallel link API dispatch 重编校验 | `build/build-fa-steps.py`（merge skip + ninja 前后断言） |
| 部署前 GPU smoke test（gfx120x 真机） | `python test/gpu-smoke-test.py -w .` |

Smoke test：wheel 文件名/结构（.pyd 体积、OPT_DIM kernel 符号、METADATA）→ pip 安装 → import flash_attn_2_cuda；parallel link 另在 merge 阶段断言 3 个 `fmha_*_api.obj` 被 skip 并由 ninja 重编。GPU fwd + kvcache 见 `test/gpu-smoke-test.py`（部署前在 gfx1200/gfx1201 真机手动跑）。

## 安装到 ComfyUI

```powershell
$PY = "<ComfyUI>\python_embeded\python.exe"
& $PY -m pip install .\downloaded.whl
```

启动参数：`--use-flash-attention`（替代 `--use-pytorch-cross-attention`）。

更多维护约定见 [AGENTS.md](AGENTS.md)。许可证：[MIT](LICENSE)。
