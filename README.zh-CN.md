# flash-attn-rocm-gfx1201-build

[English](README.md)

使用 GitHub Actions 为 **Windows / gfx1201 / PyTorch 2.12.0+rocm7.14.0** 编译 **FlashAttention 2 CK 后端** wheel。

工具链版本以 **`VERSION.lock.json`** 为唯一来源，经 `.github/actions/fa-read-version-lock` 注入 CI。

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
| `flash_attention_build_commit` | 每次构建精确 clone 的 commit；**升级 FA 时改此字段** |
| `flash_attention_min_commit` | gfx1201 最低要求 commit（[PR #2400](https://github.com/Dao-AILab/flash-attention/pull/2400)）；**lock 内人类可读参考** |
| `flash_attention_build_commit_date` | 上述 commit 的 UTC 时间；**lock 内人类可读参考**，不参与脚本/CI |
| `expected_wheel_pattern` | smoke test 校验 wheel 文件名 glob |
| `wheel_local_version` | wheel 版本号后的 `+local` 标签（注入 `FLASH_ATTN_LOCAL_VERSION`） |
| `wheel_artifact_name` | GitHub Actions 发布的 artifact 名称 |

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
| `skip_cache_restore` | `true` | 测试阶段跳过 cache restore；稳定后改为 `false` |

### 串行（`build-fa2-ck-gfx1201-serial.yml`）

| Job | 作用 | 超时 |
|-----|------|------|
| `prep-fa-src` | clone + patch，上传源码 artifact | 45 min |
| `build-win-gfx1201` | toolchain、cache、`build-bdist-wheel.ps1`（全量） | 6 h |

### 并行（`build-fa2-ck-gfx1201-parallel.yml`）

| Job | 作用 | 超时 |
|-----|------|------|
| `prep-fa-src` | 同上 | 45 min |
| `compile-d32` … `d256` | 各编一个 OPT_DIM shard，上传 `.obj` | 各 6 h |
| `link-wheel` | 合并 obj + link + 打 wheel + CPU smoke test | 6 h |

- Cache key 含仓库 commit-id 与工具链指纹（MSVC 工具集 + ROCm clang + pip 工具链版本）；**仅精确匹配**（无 `restore-keys`）。串行 `serial-v4`，并行 `parallel-v4-d{dim}`，互不共用。
- 四 shard 各编 shared obj；link 仅使用 **lock `opt_dim` 第一档**（当前 `32`）的 shared obj。

### 构建阶段

| 阶段 | 入口 | OPT_DIM |
|------|------|---------|
| 串行 build | `link_parallel_wheel.py`（无 staging）→ `bdist_wheel` | 全量 |
| 并行 compile | `link_parallel_wheel.py --compile-only` | 单 shard |
| 并行 link | `link_parallel_wheel.py` + staging | 全量（env） |

共用 `env/init-fa-build-env.ps1` + 同进程 `exec_module(setup.py)`。

## 产物

Artifact：**`wheel_artifact_name`**

- `flash_attn-*.whl`
- `flash_attn-*.whl.sha256`
- `wheel.manifest.json`

预期文件名（`expected_wheel_pattern`）：

```text
flash_attn-*+rocm714torch212cxx11abiTRUE-cp312-cp312-win_amd64.whl
```

## 验证

| 检查 | 脚本 |
|------|------|
| CI CPU smoke test | `build/test/smoke-test-wheel.ps1` |
| 部署前 GPU smoke test（gfx1201 真机） | `build/test/gpu-smoke-test.ps1` |

CPU smoke test：wheel 文件名/结构（.pyd 体积、OPT_DIM 符号、METADATA）→ pip 安装 → import flash_attn_2_cuda。**不等于** gfx1201 kernel 正确 — 部署前须在 GPU 上跑 `gpu-smoke-test.ps1`（覆盖 fwd + kvcache/appendkv/splitkv）。

## 安装到 ComfyUI

```powershell
$PY = "<ComfyUI>\python_embeded\python.exe"
& $PY -m pip install .\downloaded.whl
```

启动参数：`--use-flash-attention`（替代 `--use-pytorch-cross-attention`）。

更多维护约定见 [AGENTS.md](AGENTS.md)。
