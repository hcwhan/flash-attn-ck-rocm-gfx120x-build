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
| flash-attention | 最新 tag（`v2.8.3.post1`） |
| Runner | `windows-2022`（仅 GitHub 托管） |

## 触发方式

- 手动：Actions -> **Build FlashAttention CK (Windows gfx1201)** -> Run workflow
- 打 tag：`fa-ck-v*`

> 推送到 `main` **不会**自动触发编译（避免推送 workflow 修复时与手动触发重复跑两次）。

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
