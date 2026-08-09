# flash-attn-rocm-gfx1201-build

[English](README.en-US.md)

使用 GitHub Actions 为 **Windows / gfx1201 / PyTorch 2.12.0+rocm7.14.0** 编译 **FlashAttention 2 CK 后端** wheel。

工具链版本以 **`VERSION.lock.json`** 为唯一来源，经 `.github/actions/01.fa-read-version-lock` 注入 CI。

## 目标环境

| 项 | 值 |
|----|-----|
| GPU 架构 | `gfx1201`（RDNA4，Navi 48） |
| 系统 | Windows |
| Python | 3.12 |
| PyTorch | `2.12.0+rocm7.14.0` |
| flash-attention | `VERSION.lock.json` **`flash_attention_build_commit`** |
| Runner | `windows-2022`（GitHub 托管） |

### FlashAttention 源码 pin（`VERSION.lock.json`）

| 字段 | 作用 |
|------|------|
| `flash_attention_repo` | upstream git 地址 |
| `flash_attention_build_commit` | 每次构建精确 clone 的 commit；**升级 FA 时改此字段及 `flash_attention_build_commit_date`** |
| `flash_attention_min_commit` | gfx1201 最低要求 commit（[PR #2400](https://github.com/Dao-AILab/flash-attention/pull/2400)）；**lock 内人类可读参考** |
| `flash_attention_build_commit_date` | 上述 commit 的 UTC 时间；解析为 `SOURCE_DATE_EPOCH`，固定 PE TimeDateStamp 与 wheel zip 时间戳；**升级 commit 时须同步更新** |
| `expected_wheel_pattern` | smoke test 校验 wheel 文件名 glob |
| `wheel_local_version` | wheel 版本号后的 `+local` 标签（注入 `FLASH_ATTN_LOCAL_VERSION`） |
| `wheel_artifact_name` | GitHub Actions 发布的 artifact 名称 |
| `release_tag_prefix` | Release tag 前缀（最终 tag = `{prefix}-{variant}-build{run_number}`，variant 来自 workflow，如 `serial` / `parallel`） |
| `release_name` | Release 标题 |
| `release_prerelease` | `"true"` / `"false"`，是否预发布 |

规则：CI 始终 clone **`flash_attention_build_commit`**（`fetch` + `checkout FETCH_HEAD`）。

### 适用显卡（`gfx1201`）

| 类别 | 型号 |
|------|------|
| 消费级 | Radeon RX 9070 XT / RX 9070 / RX 9070 GRE |
| 专业级 | Radeon AI PRO R9700 / R9700S / R9600D |

> **`gfx1200`** 型号（如 RX 9060 系列）不在本 wheel 目标内。

## 编译配置

ComfyUI **推理专用** wheel：

- CK 内核：**fwd + fwd_appendkv + fwd_splitkv**（无 bwd）
- **`-DFLASHATTENTION_DISABLE_BACKWARD`**
- **C++11 ABI `cxx11abiTRUE`**（与 pin 的 PyTorch 一致）
- `OPT_DIM=32,64,128,256`

| 范围 | 约计 ninja targets |
|------|-------------------|
| link 汇总全量 | **~924** |
| 单 OPT_DIM shard | **~230** |

## 触发方式

| Workflow | 用途 | 触发 |
|----------|------|------|
| **Build FlashAttention CK serial (Windows gfx1201)** | 单 job 全量编译 + cache（`serial-v4`） | **仅手动** |
| **Build FlashAttention CK parallel (Windows gfx1201)** | OPT_DIM 分片 compile + link（`parallel-v4-d{dim}`） | **仅手动** |

> 推送到 `main` **不会**自动触发编译。

**手动输入（两个 workflow 均有）：**

| 输入 | 默认 | 说明 |
|------|------|------|
| `ninja_workers` | `4` | Ninja 并行 worker 数（OOM 时可改为 `2`） |
| `skip_cache_restore` | `false` | 设为 `true` 时跳过 cache restore（仅 lookup 探测，仍会在编译后保存） |
| `publish_release` | `true` | 设为 `false` 时跳过 GitHub Release 上传 |

### 串行（`build-fa2-ck-gfx1201-serial.yml`）

| Job | 作用 | 超时 |
|-----|------|------|
| `prep-fa-src` | clone + patch，上传源码 artifact | 45 min |
| `build-win-gfx1201` | toolchain、cache、`build/7.wheel - build-bdist-wheel.ps1`（全量） | 6 h |

### 并行（`build-fa2-ck-gfx1201-parallel.yml`）

| Job | 作用 | 超时 |
|-----|------|------|
| `prep-fa-src` | 同上 | 45 min |
| `compile-d32` … `d256` | 各编一个 OPT_DIM shard，上传 `.obj` | 各 6 h |
| `link-wheel` | 合并 obj + link + 打 wheel + CPU smoke test | 6 h |

- Cache key 含仓库 commit-id 与工具链指纹（MSVC 工具集 + ROCm clang + pip 工具链版本）；**仅精确匹配**（无 `restore-keys`）。串行 `serial-v4`，并行 `parallel-v4-d{dim}`，互不共用。
- 四 shard 各编 shared obj；link 仅使用 **lock `opt_dim` 第一档**（当前 `32`）的 shared obj。

### 构建阶段

编译/打 wheel 唯一入口：`build-fa-steps.py`（同进程 `exec_module(setup.py)`），按 `--step` 三选一：

| step | 作用 |
|------|------|
| `compile` | `build_ext` 编译；stamp 已有对象，让 ninja 缓存生效 |
| `wheel` | stamp + `bdist_wheel`（对象来自原地编译） |
| `merge-and-wheel` | staging 校验 + FORCE_BUILD 检查 + merge 对象 + stamp + `bdist_wheel` |

串行 / 并行共用同一入口编排，产物相同：

| 模式 | 调用序列 | OPT_DIM |
|------|---------|---------|
| 串行 build | `--step compile` → `--step wheel`（无 staging） | 全量 |
| 并行 compile | `--step compile`（每 shard 一次） | 单 shard |
| 并行 link | `--step merge-and-wheel` + staging | 全量（env） |

env 统一经 `base/init-fa-build-env.ps1`（含 `SOURCE_DATE_EPOCH`，取自 `flash_attention_build_commit_date`）。

## 产物

Artifact：**`wheel_artifact_name`**（Actions 短期下载）

同一 `VERSION.lock.json` 下，**serial / parallel 应产出 byte-identical wheel**（SHA256 一致）；可重现性锚点为 `flash_attention_build_commit_date`。

GitHub Release（构建成功后自动上传；serial / parallel 使用不同 tag 与标题）：

| Workflow | Tag 示例 | Release 标题示例 |
|----------|----------|------------------|
| serial | `fa2-ck-gfx1201-rocm714-serial-build123` | FlashAttention 2 CK gfx1201 Windows (serial) (build 123) |
| parallel | `fa2-ck-gfx1201-rocm714-parallel-build123` | FlashAttention 2 CK gfx1201 Windows (parallel) (build 123) |

- `flash_attn-*.whl`
- `flash_attn-*.whl.sha256`
- `wheel.manifest.json`

```powershell
gh release list
gh release download fa2-ck-gfx1201-rocm714-serial-build123 -D .\dist
gh release download fa2-ck-gfx1201-rocm714-parallel-build123 -D .\dist
```

预期文件名（`expected_wheel_pattern`）：

```text
flash_attn-*+rocm714torch212cxx11abiTRUE-cp312-cp312-win_amd64.whl
```

## 验证

| 检查 | 脚本 |
|------|------|
| CI smoke test（CPU） | `build/8.verify - wheel-smoke-test.ps1` |
| parallel link API dispatch 重编校验 | `base/build-fa-steps.py`（merge skip + ninja 前后断言） |
| 部署前 GPU smoke test（gfx1201 真机） | `test/gpu-smoke-test.ps1` |

Smoke test：wheel 文件名/结构（.pyd 体积、OPT_DIM kernel 符号、METADATA）→ pip 安装 → import flash_attn_2_cuda；parallel link 另在 merge 阶段断言 3 个 `fmha_*_api.obj` 被 skip 并由 ninja 重编。GPU fwd + kvcache 见 `test/gpu-smoke-test.ps1`（部署前在真机手动跑）。

## 安装到 ComfyUI

```powershell
$PY = "<ComfyUI>\python_embeded\python.exe"
& $PY -m pip install .\downloaded.whl
```

启动参数：`--use-flash-attention`（替代 `--use-pytorch-cross-attention`）。

更多维护约定见 [AGENTS.md](AGENTS.md)。
