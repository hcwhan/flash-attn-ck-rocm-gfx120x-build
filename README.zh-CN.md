# flash-attn-rocm-gfx1201-build

[English](README.md)

使用 GitHub Actions 为 **Windows / gfx1201 / PyTorch 2.12.0+rocm7.14.0** 编译 **FlashAttention 2 CK 后端** wheel。

## 目标环境

| 项 | 值 |
|----|-----|
| GPU | AMD RDNA4（`gfx1201`，如 RX 9070） |
| 系统 | Windows |
| Python | 3.12 |
| PyTorch | `2.12.0+rocm7.14.0` |
| flash-attention | `main`（含 PR [#2400](https://github.com/Dao-AILab/flash-attention/pull/2400) RDNA4 支持；tag `v2.8.3.post1` 不含 `gfx1201`） |
| Runner | `windows-2022`（仅 GitHub 托管） |

## 触发方式

- 手动：Actions -> **Build FlashAttention CK (Windows gfx1201)** -> Run workflow
- 打 tag：`fa-ck-v*`

> 推送到 `main` **不会**自动触发编译（避免推送 workflow 修复时与手动触发重复跑两次）。

## 编译配置

本 workflow 为 ComfyUI **推理专用** wheel：

- CK 内核：仅 **fwd**（不含 bwd / kv-cache 变体）
- `OPT_DIM=32,64,128,256`（与 upstream 默认 head dim 档一致）
- 适配 GitHub 托管 runner **6 小时**上限；完整 upstream 编译需 20 小时+

### CI 策略（两 job + 断点续编）

| Job | 作用 | 超时 |
|-----|------|------|
| `prep-fa-src` | clone + patch，上传源码 artifact | 45 min |
| `build-win-gfx1201` | 装 toolchain、恢复 cache、`pip wheel` | 6 h |

- **Prep / Build 拆分**：编译 job 不再消耗 clone/patch 时间，多争取约 20–40 min 缓冲。
- **actions/cache**：缓存 `build/`（含 ninja `.obj`）；`save-always: true`，6h 超时后 **Re-run workflow** 可增量续编（同一 `flash_attn_ref` + 相同 patch 脚本）。

> 超时续编：Actions → 失败/取消的 run → **Re-run all jobs**（不要 Re-run failed jobs only，否则 prep artifact 可能缺失）。

## Workflow 结构

两阶段 job，各自独立计时：

| Job | 内容 | 超时 |
|-----|------|------|
| `prep-fa-src` | clone + patch flash-attention，上传源码 artifact | 45 min |
| `build-win-gfx1201` | 安装 torch/rocm、恢复 cache、编译 wheel | 6 h |

`build` job 不再消耗 clone/patch 时间，编译窗口更长。

## 断点续编（cache）

`build` job 用 `actions/cache` 缓存 `C:\fa\flash-attention\build`（含 ninja `.obj` 与 generate 输出）。
若 6h 超时或编译失败，**用相同 `flash_attn_ref` 重新 Run workflow**（无需改参数）即可增量续编。
cache key 绑定 PyTorch 版本、`GPU_ARCHS`、`OPT_DIM`、patch 脚本 hash、`flash_attn_ref`；换 ref 或改 patch 会冷启动。

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
