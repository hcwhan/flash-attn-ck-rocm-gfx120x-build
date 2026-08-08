# flash-attn-rocm-gfx1201-build

[English](README.md)

使用 GitHub Actions 为 **Windows / gfx1201 / PyTorch 2.12.0+rocm7.14.0** 编译 **FlashAttention 2 CK 后端** wheel。

工具链版本以 **`VERSION.lock.json`** 为唯一来源，经 `.github/actions/fa-read-version-lock` 注入 CI（workflow 不再重复硬编码版本号）。

## 目标环境

| 项 | 值 |
|----|-----|
| GPU 架构 | `gfx1201`（RDNA4，Navi 48） |
| 适用显卡 | 见下表 |
| 系统 | Windows |
| Python | 3.12 |
| PyTorch | `2.12.0+rocm7.14.0` |
| flash-attention | `5301a359…`（`VERSION.lock.json` **`flash_attention_build_commit`**） |
| Runner | `windows-2022`（仅 GitHub 托管） |

### FlashAttention 源码 pin（`VERSION.lock.json`）

| 字段 | 作用 |
|------|------|
| `flash_attention_repo` | upstream git 地址 |
| `flash_attention_min_commit` | gfx1201 支持的最低 commit（[PR #2400](https://github.com/Dao-AILab/flash-attention/pull/2400)）；极少修改 |
| `flash_attention_build_commit` | 每次构建精确 clone 的 commit；**升级 FA 时改此字段** |
| `expected_wheel_pattern` | 构建产物 `.whl` 文件名 glob（smoke test 校验） |
| `wheel_artifact_name` | GitHub Actions 发布的 wheel -bundle artifact 名称 |

规则：

- CI/本地始终 clone **`flash_attention_build_commit`**（无 workflow ref 输入）。
- prep 校验 **`flash_attention_build_commit`** **不早于** **`flash_attention_min_commit`**（`git merge-base --is-ancestor`）。
- tag `v2.8.3.post1` 的 `allowed_archs` 不含 `gfx1201` — 勿将 `flash_attention_build_commit` 设低于最低要求。

### 适用显卡（`gfx1201`）

来源：[AMD ROCm GPU specifications](https://rocm.docs.amd.com/en/latest/reference/gpu-arch-specs.html)

| 类别 | 型号 |
|------|------|
| 消费级 | Radeon RX 9070 XT |
| 消费级 | Radeon RX 9070 |
| 消费级 | Radeon RX 9070 GRE |
| 专业级 | Radeon AI PRO R9700 |
| 专业级 | Radeon AI PRO R9700S |
| 专业级 | Radeon AI PRO R9600D |

> RDNA4 **`gfx1200`** 型号（如 RX 9060 / RX 9060 XT）为不同 LLVM target，**不包含**在本 wheel 中。

## 编译配置

本 workflow 为 ComfyUI **推理专用** wheel：

- CK 内核：**fwd + fwd_appendkv + fwd_splitkv**（`generate.py` 不跑 **bwd** 方向 → wheel 内**不含** `fmha_bwd_*` backward kernel；前向推理正常，**不支持**需对 attention 求梯度的场景，如扩散模型训练、LoRA/微调中对 `flash_attn` 的反传）
- 编译宏 **`-DFLASHATTENTION_DISABLE_BACKWARD`**（`patch-fa-inference.ps1` 直接修改并经修改前/后校验；`setup-rocm-env.ps1` 设 `FLASHATTENTION_DISABLE_BACKWARD=TRUE`）— 编译期去掉 extension 内 backward 相关 C++ 分支；与上条互补，**不支持训练/反传**
- **推理专用范围**（不在 `VERSION.lock.json` 中）：本仓库始终构建仅前向 wheel；勿期望 `flash_attn` 反传 API 或训练流程可用
- **C++11 ABI（`cxx11abiTRUE`）**（不在 `VERSION.lock.json` 中）：extension 须与 pin 的 PyTorch 一致，使用 `_GLIBCXX_USE_CXX11_ABI=1`（官方 ROCm 2.12 wheel）。ABI 不一致通常导致 `import flash_attn_2_cuda` 失败。smoke test 通过 `VERSION.lock.json` 的 `expected_wheel_pattern` 间接校验（含 `cxx11abiTRUE` 标签）
- `OPT_DIM=32,64,128,256`（与 upstream 默认 head dim 档一致）
- **`link_parallel_wheel.py` monkey-patch**（不在 `VERSION.lock.json` 中）：并行 link 会 patch `torch.utils.cpp_extension._run_ninja_build` 以合并预编译 `.obj`；升级 pin 的 PyTorch 版本后须重新验证
- 适配 GitHub 托管 runner **6 小时**上限；完整 upstream 编译需 20 小时+

### Ninja 编译规模（推理专用配置）

| 范围 | 约计 ninja targets | 说明 |
|------|-------------------|------|
| 全量（串行 / link 汇总） | **~924** | 3 方向（fwd + fwd_appendkv + fwd_splitkv）× 4 head dim，无 bwd |
| 单 OPT_DIM shard（并行 compile） | **~230** | 共享 `csrc/flash_attn_ck` + 单档 dim 的 `build/fmha_*_dNN_*` kernel |

> 全量 upstream（含 bwd）约 **1837** targets，6h 内无法完成。

## 触发方式

| Workflow | 用途 | 触发 |
|----------|------|------|
| **Build FlashAttention CK serial (Windows gfx1201)** | 单 job 编译 + cache 断点续编（`serial-v2`） | **仅手动** |
| **Build FlashAttention CK parallel (Windows gfx1201)** | lock 中 `OPT_DIM` 分片编译 + artifact 分片 + cache 断点续编（`parallel-v2-d{dim}`）+ link 汇总 | **仅手动** |

> 推送到 `main` **不会**自动触发编译。

**手动输入（两个 workflow 均有）：**

| 输入 | 默认 | 说明 |
|------|------|------|
| `ninja_workers` | `4` | Ninja 并行编译 worker 数（非 CI job 数；OOM 时可改为 `2`） |

> FA 源码始终 clone **`VERSION.lock.json`** 的 **`flash_attention_build_commit`**，且须满足 **`flash_attention_min_commit`** 下限。

### 共用组件

两个 workflow 共用：

- `.github/actions/fa-read-version-lock` — 从 `VERSION.lock.json` 加载版本到 `GITHUB_ENV`
- `.github/actions/fa-prep-artifact` — clone + patch + 上传源码（输出解析后的 **FA commit SHA**）
- `.github/actions/fa-rocm-toolchain` — Python / MSVC / torch / rocm devel
- `.github/actions/fa-download-src` — 下载 prep artifact
- `build/patch-fa-inference.ps1` — 直接修改 `setup.py`，含修改前/后校验
- `build/prep-flash-attention.ps1`、`build/init-fa-build-env.ps1`、`build/setup-rocm-env.ps1`、`build/build-bdist-wheel.ps1`、`build/smoke-test-wheel.ps1`

串行 / 并行 link / 并行 compile 共用 `init-fa-build-env.ps1` + 同进程 `link_parallel_wheel.py`；并行 compile 额外使用 `build/compile-opt-dim.ps1`。`build/validate-link-staging.ps1` 仅作本地/手动 CLI 包装（CI link 阶段由 `link_parallel_wheel.py` 内建校验）。

### 构建路径对齐

| 阶段 | 环境初始化 | setuptools 入口 | OPT_DIM |
|------|-----------|----------------|---------|
| 串行 build | `init-fa-build-env.ps1` | `link_parallel_wheel.py --serial` → `bdist_wheel -v` | 全量 |
| 并行 compile | `init-fa-build-env.ps1` | `link_parallel_wheel.py --compile-only` → `build_ext -v` | 单 shard |
| 并行 link | `init-fa-build-env.ps1` | `link_parallel_wheel.py` + staging → `bdist_wheel -v` | 全量 |

三者均为 **同进程 `exec_module(setup.py)`**，共用 `NinjaBuildExtension`；并行 compile 不再使用 `--inplace` 子进程。与串行/link 的唯一实质差异是 **OPT_DIM 范围** 与 **build_ext vs bdist_wheel**（compile 只产出 obj，不打包 wheel）。

## CI 策略

### 串行（`build-fa2-ck-gfx1201-serial.yml`，默认）

| Job | 作用 | 超时 |
|-----|------|------|
| `prep-fa-src` | clone + patch，上传源码 artifact | 45 min |
| `build-win-gfx1201` | 装 toolchain、恢复 cache、`build-bdist-wheel.ps1` | 6 h |

- **Prep / Build 拆分**：编译 job 保留完整 6h 给 ninja。
- **`actions/cache/restore` + `actions/cache/save`**：缓存 `build/`，key 前缀 `serial-v2`，save 步骤 `if: always()`；超时后 **Re-run all jobs** 可增量续编。
- **Cache key** 包含 prep 解析出的 **flash-attention commit SHA**（`VERSION.lock.json` 锁定），避免 bump lock 后复用过期 `.obj`。**仅精确 key 匹配**，无跨 commit 的 `restore-keys` 回退。

### 并行（`build-fa2-ck-gfx1201-parallel.yml`，OPT_DIM ×4）

| Job | 作用 | 超时 |
|-----|------|------|
| `prep-fa-src` | 同上（共用 prep action） | 45 min |
| `compile-d*` … | 各编 lock 中一个 `OPT_DIM` shard，恢复 cache、上传 `.obj` | 各 6 h |
| `link-wheel` | 校验 4 份 staging → 合并 obj + link + 打 wheel | 6 h |

墙钟更短（约 1–2h），但总 runner 分钟数更高。产物与串行 workflow 相同。

- **link 前置校验**：`link_parallel_wheel.py` 在 merge/link 前校验 staging（四目录齐全、各 shard 含对应 dim kernel obj、无跨 shard 污染）。
- **actions/cache**：各 shard 缓存 `build/`，key 前缀 `parallel-v2-d{dim}`（含解析后的 FA commit SHA）；**仅精确 key 匹配**（无跨 commit 的 `restore-keys`）；超时后 **Re-run failed jobs** 可增量续编（obj/源码 artifact 保留 **7 天**）。
- **link-wheel** 仍须 4 个 compile job 均成功并上传 obj artifact。
- 各 compile shard 也会编译共享 `csrc/flash_attn_ck` obj；link 阶段仅使用 **lock `opt_dim` 第一档** shard 的共享 obj（重复编译属预期行为）。

> cache key 互相隔离：串行 `serial-v2`，并行 `parallel-v2-` (`d32` / `d64` / `d128` / `d256`)，两个 workflow 不共用 cache 条目。

## 产物

Artifact 名称：**`VERSION.lock.json` 的 `wheel_artifact_name`**（当前为 `flash-attn-ck-gfx1201-cp312-rocm714`）

包含：

- `flash_attn-*.whl`
- `flash_attn-*.whl.sha256`（GNU `sha256sum` 格式）
- `wheel.manifest.json`（sha256、大小、工具链 pin、FA commit）

预期 wheel 文件名模式（lock 中 `expected_wheel_pattern`）：

```text
flash_attn-*+rocm714torch212cxx11abiTRUE-cp312-cp312-win_amd64.whl
```

## 验证

| 检查 | 脚本 | 验证内容 |
|------|------|----------|
| CI CPU smoke test | `build/smoke-test-wheel.ps1` | wheel 文件名匹配 `VERSION.lock.json`、SHA256 校验和 + manifest、pip 安装、extension import |
| 本地 GPU smoke test | `build/gpu-smoke-test.ps1` | gfx1201 上实际运行 `flash_attn_func` 前向（需 ROCm PyTorch + GPU） |

> CI 运行在 GitHub **托管** runner 上，无 AMD GPU — **CI 通过不等于 GPU 内核正确**。部署到 ComfyUI 前请在 RX 9070 机器上运行 `gpu-smoke-test.ps1`。

## 本地构建（CI 外）

在已安装 MSVC、Python 3.12、PyTorch ROCm 的 Windows 机器上：

```powershell
cd flash-attn-rocm-gfx1201-build
. .\build\build-local.ps1 -GpuSmokeTest
```

可选参数：`-SkipPrep`（复用已有 `$FaSrc`）、`-NinjaWorkers 2`（OOM 时）。

## 安装到 ComfyUI 便携 Python

将 `<ComfyUI>` 替换为你的 ComfyUI 根目录：

```powershell
$PY = "<ComfyUI>\python_embeded\python.exe"
& $PY -m pip install .\downloaded.whl
```

然后将 ComfyUI 启动参数从 `--use-pytorch-cross-attention` 改为 `--use-flash-attention`。

## 仓库地址

https://github.com/hcwhan/flash-attn-rocm-gfx1201-build
