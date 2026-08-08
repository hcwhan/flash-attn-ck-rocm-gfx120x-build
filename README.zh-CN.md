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

- CK 内核：**fwd + fwd_appendkv + fwd_splitkv**（不含 **bwd** 训练内核）
- `OPT_DIM=32,64,128,256`（与 upstream 默认 head dim 档一致）

## 触发方式

| Workflow | 用途 | 触发 |
|----------|------|------|
| **Build FlashAttention CK (Windows gfx1201)** | 单 job 编译 + cache 断点续编 | 手动 / tag `fa-ck-v*` |
| **Build FlashAttention CK parallel (Windows gfx1201)** | 4 路 `OPT_DIM` 并发编译 + link 汇总 | **仅手动** |

> 推送到 `main` **不会**自动触发编译。

### 共用组件

两个 workflow 共用：

- `.github/actions/fa-prep-artifact` — clone + patch + 上传源码
- `.github/actions/fa-rocm-toolchain` — Python / MSVC / torch / rocm devel
- `.github/actions/fa-download-src` — 下载 prep artifact
- `build/prep-flash-attention.ps1`、`build/setup-rocm-env.ps1`、`build/smoke-test-wheel.ps1`

并行 workflow 额外使用：`build/compile-opt-dim.ps1`、`build/link_parallel_wheel.py`。

## CI 策略

### 串行（默认）

| Job | 作用 | 超时 |
|-----|------|------|
| `prep-fa-src` | clone + patch，上传源码 artifact | 45 min |
| `build-win-gfx1201` | 装 toolchain、恢复 cache、`pip wheel` | 6 h |

- **Prep / Build 拆分**：编译 job 保留完整 6h 给 ninja。
- **actions/cache**：缓存 `build/`；超时后 **Re-run all jobs** 可增量续编。

### 并行（OPT_DIM ×4）

| Job | 作用 | 超时 |
|-----|------|------|
| `prep-fa-src` | 同上（共用 prep action） | 45 min |
| `compile-d32` … `compile-d256` | 各编一个 `OPT_DIM` shard，上传 `.obj` | 各 6 h |
| `link-wheel` | 合并 4 份 obj + link + 打 wheel | 6 h |

墙钟更短（约 1–2h），但总 runner 分钟数更高。产物与串行 workflow 相同。

> 超时续编：串行走 cache；并行需 4 个 compile job 均成功后再 link。

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
