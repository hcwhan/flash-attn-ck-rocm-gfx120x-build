# flash-attn-rocm-gfx1201-build

[English](README.md)

使用 GitHub Actions 为 **Windows / gfx1201 / PyTorch 2.12.0+rocm7.14.0** 编译 **FlashAttention 2 CK 后端** wheel。

## 目标环境

| 项 | 值 |
|----|-----|
| GPU 架构 | `gfx1201`（RDNA4，Navi 48） |
| 适用显卡 | 见下表 |
| 系统 | Windows |
| Python | 3.12 |
| PyTorch | `2.12.0+rocm7.14.0` |
| flash-attention | `main`（含 PR [#2400](https://github.com/Dao-AILab/flash-attention/pull/2400) RDNA4 支持；tag `v2.8.3.post1` 不含 `gfx1201`） |
| Runner | `windows-2022`（仅 GitHub 托管） |

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
- 编译宏 **`-DFLASHATTENTION_DISABLE_BACKWARD`**（`patch-fa-inference.ps1` 启用；`setup-rocm-env.ps1` 设 `FLASHATTENTION_DISABLE_BACKWARD=TRUE`）— 编译期去掉 extension 内 backward 相关 C++ 分支；与上条互补，**不支持训练/反传**
- `OPT_DIM=32,64,128,256`（与 upstream 默认 head dim 档一致）
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
| **Build FlashAttention CK parallel (Windows gfx1201)** | 4 路 `OPT_DIM` 并发编译 + artifact 分片 + cache 断点续编（`parallel-v2-d{dim}`）+ link 汇总 | **仅手动** |

> 推送到 `main` **不会**自动触发编译。

**手动输入（两个 workflow 均有）：**

| 输入 | 默认 | 说明 |
|------|------|------|
| `flash_attn_ref` | `main` | branch / tag / **commit SHA** |
| `max_jobs` | `4` | ninja 并行度（OOM 时可改为 `2`） |
| `use_locked_commit` | `false` | 为 `true` 时使用 `VERSION.lock.json` 的 **`flash_attention_min_commit`** 锁定 FA 源码 |

### 共用组件

两个 workflow 共用：

- `.github/actions/fa-prep-artifact` — clone + patch + 上传源码
- `.github/actions/fa-rocm-toolchain` — Python / MSVC / torch / rocm devel
- `.github/actions/fa-download-src` — 下载 prep artifact
- `build/prep-flash-attention.ps1`、`build/init-fa-build-env.ps1`、`build/setup-rocm-env.ps1`、`build/build-bdist-wheel.ps1`、`build/smoke-test-wheel.ps1`

串行 / 并行 link / 并行 compile 共用 `init-fa-build-env.ps1` + 同进程 `link_parallel_wheel.py`；并行 compile 额外使用 `build/compile-opt-dim.ps1`、`build/validate-link-staging.ps1`。

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
- **actions/cache**：缓存 `build/`，key 前缀 `serial-v2`；超时后 **Re-run all jobs** 可增量续编。

### 并行（`build-fa2-ck-gfx1201-parallel.yml`，OPT_DIM ×4）

| Job | 作用 | 超时 |
|-----|------|------|
| `prep-fa-src` | 同上（共用 prep action） | 45 min |
| `compile-d32` … `compile-d256` | 各编一个 `OPT_DIM` shard，恢复 cache、上传 `.obj` | 各 6 h |
| `link-wheel` | 校验 4 份 staging → 合并 obj + link + 打 wheel | 6 h |

墙钟更短（约 1–2h），但总 runner 分钟数更高。产物与串行 workflow 相同。

- **link 前置校验**：`validate-link-staging.ps1` 检查 `d32`/`d64`/`d128`/`d256` 目录齐全、各 shard 含对应 dim kernel obj、无跨 shard 污染。
- **actions/cache**：各 shard 缓存 `build/`，key 前缀 `parallel-v2-d{dim}`；restore-keys 仅匹配同 hash 前缀（不再宽泛匹配 `-gfx1201-`）；超时后 **Re-run failed jobs** 可增量续编。
- **link-wheel** 仍须 4 个 compile job 均成功并上传 obj artifact。

> cache key 互相隔离：串行 `serial-v2`，并行 `parallel-v2-` (`d32` / `d64` / `d128` / `d256`)，两个 workflow 不共用 cache 条目。

## 产物

Artifact 名称：`flash-attn-ck-gfx1201-cp312-rocm714`

预期 wheel 文件名模式：

```text
flash_attn-*+rocm714torch212cxx11abiTRUE-cp312-cp312-win_amd64.whl
```

## 安装到 ComfyUI 便携 Python

将 `<ComfyUI>` 替换为你的 ComfyUI 根目录：

```powershell
$PY = "<ComfyUI>\python_embeded\python.exe"
& $PY -m pip install .\downloaded.whl
```

然后将 ComfyUI 启动参数从 `--use-pytorch-cross-attention` 改为 `--use-flash-attention`。

## 仓库地址

https://github.com/hcwhan/flash-attn-rocm-gfx1201-build
